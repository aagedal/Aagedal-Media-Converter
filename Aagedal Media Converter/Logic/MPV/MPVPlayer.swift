// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import AppKit
import Libmpv
import Libavfilter
import OSLog

/// The C callback owns this box, never the player. It only schedules work: resolving
/// the weak player on libmpv's callback thread could run its deinit under mpv's
/// wakeup lock, deadlocking when teardown unregisters that same callback.
final class MPVWakeupContext: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void

    init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.handler = handler
    }

    func schedule() {
        queue.async(execute: handler)
    }
}

/// MPV Player - NOT an actor to allow background thread access for event handling
/// All @Published property updates are dispatched to main thread
/// Marked @unchecked Sendable because we handle thread safety manually with DispatchQueue
final class MPVPlayer: NSObject, ObservableObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVPlayer")

    // MPV context
    private var mpv: OpaquePointer?
    private var metalLayer: MPVMetalLayer?
    private let queue = DispatchQueue(label: "com.aagedal.mpv", qos: .userInitiated)
    private var seekScheduler = MPVSeekScheduler()
    private let eventQueueKey = DispatchSpecificKey<Bool>()

    // Published properties for playback state
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var timePos: Double = 0
    @Published var volume: Double = 100 {
        didSet {
            setDouble(MPVProperty.volume, volume)
        }
    }
    @Published var isMuted: Bool = false {
        didSet {
            setFlag(MPVProperty.mute, isMuted)
        }
    }
    @Published var isSeekable = false
    @Published var isBusy = false
    @Published var isFileLoaded = false
    @Published var error: String?
    @Published var reachedEnd = false

    /// Active libmpv audio backend, used when diagnosing playback/device failures.
    var currentAudioOutput: String? { getString("current-ao") }

    // All filter/timer state belongs to the event queue. The optional analysis
    // filter only runs while requested. Source inspection remains separate.
    @Published private(set) var playbackMeterSample: PlaybackAudioMeterSample?
    @Published private(set) var playbackMeterUnavailable = false
    private(set) var playbackMeterHasTimestampHistory = false
    private(set) var playbackMeterHistoryIngestSeconds: Double?
    private var meterHistoryLastIngestSeconds: Double?
    // Diagnostic opt-in until the clean dependency package and app clocks are qualified.
    private let meterUsesHistory: Bool = {
#if DEBUG
        ProcessInfo.processInfo.environment["AMC_PLAYBACK_METER_HISTORY"] == "1"
#else
        false
#endif
    }()
    private let meterClockProperty: String = {
#if DEBUG
        if ProcessInfo.processInfo.environment["AMC_PLAYBACK_METER_CLOCK"] == "audio-pts" { return "audio-pts" }
#endif
        return "time-pos"
    }()
    private var meterHistory = MPVAudioMeterHistory()
    private var meterHistoryMisses = 0
    private var meterHistoryInitialized = false
    private var meterHistoryRestarts: [Double] = []
    static var supportsPlaybackMeter: Bool {
        (["astats", "ebur128"] as [String]).allSatisfy { name in
            name.withCString { avfilter_get_by_name($0) != nil }
        }
    }
    private var meterRequested = false // Main-thread presentation intent
    private var meterEnabled = false
    private var meterTimer: DispatchSourceTimer?
    private let meterGenerationLock = NSLock()
    private var meterGeneration: UInt64 = 0
    private var meterPending: UInt64?
    private var meterRunning = false
    private var meterStartTime: Double?
    private static let meterLabel = "amc_playback_meter"
    private static let meterRequestMask: UInt64 = 1 << 62

    /// Opt-in decoded active-track analysis; metadata can lead audible output.
    func setPlaybackMeterEnabled(_ enabled: Bool) {
        meterRequested = enabled
        playbackMeterSample = nil
        playbackMeterUnavailable = enabled && !Self.supportsPlaybackMeter
        queue.async { [weak self] in
            guard let self else { return }
            self.meterEnabled = enabled && Self.supportsPlaybackMeter
            self.meterHistoryRestarts.removeAll()
            self.resetPlaybackMeterLocked()
            self.meterTimer?.cancel()
            self.meterTimer = nil
            guard self.meterEnabled else { return }
            self.preparePlaybackMeterHistoryLocked()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.pollPlaybackMeterLocked() }
            self.meterTimer = timer
            timer.resume()
        }
    }

    private func resetPlaybackMeterLocked(removeFilter: Bool = true) {
        meterGenerationLock.lock()
        meterGeneration = (meterGeneration &+ 1) & ((1 << 62) - 1)
        meterGenerationLock.unlock()
        meterStartTime = nil
        meterHistory.reset(generation: meterGeneration)
        meterHistoryMisses = 0
        meterHistoryInitialized = false
        meterHistoryLastIngestSeconds = nil
        // Keep at most one outstanding query, even across reset/seek.
        if removeFilter, meterRunning, let mpv {
            let args = ["af", "remove", "@" + Self.meterLabel]
            _ = args.withUnsafeCStringArray { mpv_command(mpv, $0) }
        }
        if removeFilter { meterRunning = false }
        DispatchQueue.main.async {
            self.playbackMeterSample = nil
            self.playbackMeterHasTimestampHistory = false
            self.playbackMeterHistoryIngestSeconds = nil
        }
    }

    private func pollPlaybackMeterLocked() {
        guard meterEnabled, let mpv, meterPending == nil else { return }
        // A history installed before a seek must survive until decoding restarts.
        // Do not accept metadata from the outgoing timeline during that interval.
        if meterUsesHistory, seekScheduler.inFlight != nil { return }
        if meterUsesHistory, meterHistory.needsFilterRestart {
            let now = ProcessInfo.processInfo.systemUptime
            meterHistoryRestarts.removeAll { now - $0 > 5 }
            guard meterHistoryRestarts.count < 3 else {
                meterEnabled = false
                resetPlaybackMeterLocked()
                DispatchQueue.main.async { self.playbackMeterUnavailable = true }
                return
            }
            meterHistoryRestarts.append(now)
            resetPlaybackMeterLocked()
        }
        var paused: Int32 = 1
        var eof: Int32 = 1
        guard mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused) >= 0,
              mpv_get_property(mpv, "eof-reached", MPV_FORMAT_FLAG, &eof) >= 0,
              paused == 0, eof == 0 else { return }
        guard installPlaybackMeterFilterLocked() else { return }
        let id = Self.meterRequestMask | meterGeneration
        if mpv_get_property_async(mpv, id, "af-metadata/" + Self.meterLabel, MPV_FORMAT_NODE) >= 0 {
            meterPending = id
        }
    }

    @discardableResult
    private func installPlaybackMeterFilterLocked() -> Bool {
        guard meterEnabled, let mpv else { return false }
        if !meterRunning {
            let graph = "ebur128=metadata=1:framelog=verbose,"
                + "astats=metadata=1:reset=1:measure_perchannel=Peak_level+RMS_level:measure_overall=none"
            let filter = "@" + Self.meterLabel + (meterUsesHistory
                ? ":lavfi=graph=[" + graph + "]:amc-meter-history=yes" : ":lavfi=[" + graph + "]")
            let status = ["af", "add", filter].withUnsafeCStringArray { mpv_command(mpv, $0) }
            guard status >= 0 else {
                meterEnabled = false
                DispatchQueue.main.async { self.playbackMeterUnavailable = true }
                return false
            }
            meterRunning = true
        }
        return true
    }

    private func preparePlaybackMeterHistoryLocked() {
        guard meterUsesHistory, meterEnabled, !meterRunning, let mpv,
              installPlaybackMeterFilterLocked() else { return }
        // Audio already queued before filter insertion has no measurements.
        // Re-decode the current position through the installed graph, using the
        // normal scheduler and preserving any newer user seek already in flight.
        guard seekScheduler.inFlight == nil, seekScheduler.pending == nil else { return }
        var seekable: Int32 = 0
        var position: Double = 0
        guard mpv_get_property(mpv, "seekable", MPV_FORMAT_FLAG, &seekable) >= 0, seekable != 0,
              mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0,
              position.isFinite, position >= 0 else { return }
        if let submission = seekScheduler.request(.init(time: position, exact: true)) {
            submitSeekLocked(submission)
        }
    }

    private func receivePlaybackMeterLocked(_ event: mpv_event) {
        guard event.reply_userdata == meterPending else { return }
        meterPending = nil
        guard meterEnabled, meterRunning,
              event.reply_userdata == (Self.meterRequestMask | meterGeneration) else { return }
        guard event.error >= 0, let data = event.data else {
            missingPlaybackMeterHistoryLocked()
            return
        }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard property.format == MPV_FORMAT_NODE, let pointer = property.data else {
            missingPlaybackMeterHistoryLocked()
            return
        }
        // Event-owned nodes must be copied before the next mpv_wait_event.
        let node = pointer.assumingMemoryBound(to: mpv_node.self).pointee
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list?.pointee,
              list.num > 0, list.num <= 512, let keys = list.keys, let values = list.values else {
            missingPlaybackMeterHistoryLocked()
            return
        }
        var metadata: [String: String] = [:]
        var copiedBytes = 0
        for index in 0..<Int(list.num) {
            guard let key = keys[index], values[index].format == MPV_FORMAT_STRING,
                  let value = values[index].u.string else { continue }
            let keyBytes = strnlen(key, 4097)
            let valueBytes = strnlen(value, 3 * 1024 * 1024 + 1)
            copiedBytes += keyBytes + valueBytes
            guard keyBytes <= 4096, copiedBytes <= 3 * 1024 * 1024 else {
                missingPlaybackMeterHistoryLocked()
                return
            }
            metadata[String(cString: key)] = String(cString: value)
        }
        var time: Double = 0
        guard let mpv, mpv_get_property(mpv, meterUsesHistory ? meterClockProperty : "time-pos", MPV_FORMAT_DOUBLE, &time) >= 0,
              time.isFinite else {
            missingPlaybackMeterHistoryLocked()
            return
        }
        let sample: PlaybackAudioMeterSample?
        if meterUsesHistory {
            guard let json = metadata["amc-meter-history-v1"] else {
                missingPlaybackMeterHistoryLocked()
                return
            }
            let ingestStarted = ProcessInfo.processInfo.systemUptime
            let outcome = meterHistory.ingest(json: json, generation: meterGeneration)
            meterHistoryLastIngestSeconds = ProcessInfo.processInfo.systemUptime - ingestStarted
            if outcome.accepted, meterHistory.bufferedFrameCount > 0 {
                meterHistoryMisses = 0
                meterHistoryInitialized = true
            } else if outcome.accepted {
                missingPlaybackMeterHistoryLocked()
            }
            sample = meterHistory.sample(at: time, generation: meterGeneration)
        } else {
            if meterStartTime == nil { meterStartTime = time }
            sample = MPVAudioMeterMetadata.sample(metadata, seconds: time,
                history: max(0, time - (meterStartTime ?? time)))
        }
        publishPlaybackMeterSampleLocked(sample, generation: meterGeneration)
    }

    private func missingPlaybackMeterHistoryLocked() {
        guard meterUsesHistory else { return }
        publishPlaybackMeterSampleLocked(nil, generation: meterGeneration)
        // Delayed tracks may not emit audio for many seconds. Initial absence is
        // unavailable, but must not repeatedly recreate a graph before audio starts.
        meterHistoryMisses = min(10, meterHistoryMisses + 1)
        if meterHistoryInitialized {
            meterHistory.markUnavailable(generation: meterGeneration)
        } else if meterHistoryMisses >= 10 {
            let generation = meterGeneration
            DispatchQueue.main.async {
                self.meterGenerationLock.lock()
                let current = self.meterGeneration == generation
                self.meterGenerationLock.unlock()
                if current, self.meterRequested { self.playbackMeterUnavailable = true }
            }
        }
    }

    private func publishPlaybackMeterSampleLocked(_ sample: PlaybackAudioMeterSample?, generation: UInt64) {
        let ingestSeconds = meterHistoryLastIngestSeconds
        DispatchQueue.main.async {
            self.meterGenerationLock.lock()
            let current = self.meterGeneration == generation
            self.meterGenerationLock.unlock()
            if current, self.meterRequested, self.isPlaying, self.isFileLoaded,
               !self.reachedEnd, self.error == nil {
                self.playbackMeterSample = sample
                self.playbackMeterHasTimestampHistory = self.meterUsesHistory && sample != nil
                self.playbackMeterHistoryIngestSeconds = ingestSeconds
                if self.playbackMeterHasTimestampHistory { self.playbackMeterUnavailable = false }
            }
        }
    }

    private var isInitialized = false
    private var startPaused = false
    private var wakeupContext: UnsafeMutableRawPointer?

    // Pending load - stored when load() is called before MPV is initialized
    private var pendingURL: URL?
    private var pendingStartTime: Double = 0
    private var pendingAutostart: Bool = false
    private var pendingSource = RemoteSource()

    /// Extras for web streams: headers the host requires and a separate audio
    /// stream for adaptive (video-only) formats.
    struct RemoteSource: Equatable {
        var externalAudioURL: URL?
        var httpHeaders: [String: String] = [:]
    }

    /// Audio to add once the current file is open. Event-queue state.
    private var externalAudioForLoad: String?
    /// Whether custom HTTP headers are set and must be cleared for the next load.
    private var hasCustomHTTPHeaders = false
    private(set) var loadGeneration: UInt64 = 0
    private static let loadCommandMask: UInt64 = 1 << 63

    // Start time to seek to after file loads (workaround for loadfile start= parsing issue)
    private var pendingSeekAfterLoad: Double = 0

    override init() {
        super.init()
        queue.setSpecific(key: eventQueueKey, value: true)
    }

    deinit {
        meterTimer?.cancel()
        if let mpv {
            // libmpv serializes callback replacement with callback execution.
            // Keep the box alive until unregistering and destroying the handle.
            mpv_set_wakeup_callback(mpv, nil, nil)
            if DispatchQueue.getSpecific(key: eventQueueKey) == true {
                // The last reference may be released by an event queue block.
                mpv_terminate_destroy(mpv)
            } else {
                queue.sync { mpv_terminate_destroy(mpv) }
            }
        }
        if let ctx = wakeupContext {
            Unmanaged<MPVWakeupContext>.fromOpaque(ctx).release()
        }
    }

    // MARK: - Metal Layer Binding

    func attachDrawable(_ layer: MPVMetalLayer) {
        // mpv keeps a raw pointer to the layer it was created with. A later
        // view's layer can't replace it, and releasing it would leave the
        // video output thread with a dangling layer on the next load.
        if mpv == nil { metalLayer = layer }
        setupMPV()

        // Process pending load if any
        if let url = pendingURL {
            let startTime = pendingStartTime
            let autostart = pendingAutostart
            let source = pendingSource
            pendingURL = nil
            pendingStartTime = 0
            pendingAutostart = false
            pendingSource = RemoteSource()
            load(url: url, startTime: startTime, autostart: autostart, source: source)
        }
    }

    private func setupMPV() {
        let setupStart = CFAbsoluteTimeGetCurrent()
        logger.info("⏱️ MPV setup starting...")

        guard mpv == nil else {
            logger.info("MPV already initialized, skipping setup")
            return
        }

        guard let metalLayer = metalLayer else {
            logger.error("Cannot setup MPV: no Metal layer attached")
            return
        }

        logger.info("⏱️ Creating mpv context...")
        mpv = mpv_create()
        guard mpv != nil else {
            logger.error("Failed to create MPV context")
            error = "Failed to create MPV context"
            return
        }

        // Configure logging
        #if DEBUG
        checkError(mpv_request_log_messages(mpv, "warn"))
        #else
        checkError(mpv_request_log_messages(mpv, "no"))
        #endif

        // Configure rendering pipeline
        var wid = unsafeBitCast(metalLayer, to: Int64.self)
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid))
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))

        // Enable HDR passthrough (EDR on macOS)
        checkError(mpv_set_option_string(mpv, "target-colorspace-hint", "yes"))

        // Keep file open after EOF to prevent Vulkan context destruction
        // This allows seeking back after playback ends
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))

        // Fast file opening options
        // Don't pause when cache runs low (cache-pause-initial was deprecated)
        checkError(mpv_set_option_string(mpv, "cache-pause", "no"))
        // Force file to be seekable (helps with MKV)
        checkError(mpv_set_option_string(mpv, "force-seekable", "yes"))
        // Drop frames during seeking for faster seek response
        checkError(mpv_set_option_string(mpv, "hr-seek-framedrop", "yes"))
        // Reduce initial demuxer readahead for faster start (default ~1s is fine)
        checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "1"))

        // Auto-detect interlaced content and deinterlace only when needed
        checkError(mpv_set_option_string(mpv, "deinterlace", "auto"))

        // Disable features we don't need
        checkError(mpv_set_option_string(mpv, "ytdl", "no"))
        checkError(mpv_set_option_string(mpv, "input-default-bindings", "no"))
        checkError(mpv_set_option_string(mpv, "input-vo-keyboard", "no"))

        // Disable built-in Lua scripts (stats, console, osc, etc.)
        // We have our own SwiftUI controls - don't need MPV's Lua-based UI
        // This also avoids LuaJIT code signing issues in notarized builds
        checkError(mpv_set_option_string(mpv, "load-scripts", "no"))

        // Disable subtitles by default - user can enable via subtitle track selector
        checkError(mpv_set_option_string(mpv, "sid", "no"))

        // macOS integration
        #if os(macOS)
        checkError(mpv_set_option_string(mpv, "input-media-keys", "no"))
        #endif

        // Initialize MPV
        checkError(mpv_initialize(mpv))

        // Controls can change before SwiftUI attaches the drawable. Apply their
        // requested values now, before opening the pending source.
        setDouble(MPVProperty.speed, Double(playbackRate))
        setDouble(MPVProperty.volume, volume)
        setFlag(MPVProperty.mute, isMuted)

        // Register property observers
        mpv_observe_property(mpv, 0, MPVProperty.timePos, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.duration, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.pause, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.seekable, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.eofReached, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.speed, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.aid, MPV_FORMAT_INT64)

        // Set wakeup callback for event handling
        // Retain only a callback box; retaining self here prevents deinit forever.
        let context = MPVWakeupContext(queue: queue) { [weak self] in
            self?.readEvents()
        }
        wakeupContext = Unmanaged.passRetained(context).toOpaque()
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let client = ctx else { return }
            let context = Unmanaged<MPVWakeupContext>.fromOpaque(client).takeUnretainedValue()
            context.schedule()
        }, wakeupContext)

        isInitialized = true
        let setupDuration = CFAbsoluteTimeGetCurrent() - setupStart
        logger.info("⏱️ MPV initialized successfully in \(String(format: "%.3f", setupDuration))s")
    }

    // MARK: - Playback Control

    private var loadStartTime: CFAbsoluteTime = 0

    func load(url: URL, startTime: Double = 0, autostart: Bool = false, source: RemoteSource = RemoteSource()) {
        loadGeneration = (loadGeneration &+ 1) & ~Self.loadCommandMask
        error = nil
        isFileLoaded = false
        reachedEnd = false
        loadStartTime = CFAbsoluteTimeGetCurrent()
        logger.info("Load starting for: \(url.lastPathComponent)")

        // A SwiftUI drawable may arrive later. Keep only the newest request.
        guard mpv != nil else {
            pendingURL = url
            pendingStartTime = startTime
            pendingAutostart = autostart
            pendingSource = source
            return
        }

        queue.sync {
            seekScheduler.reset()
            resetPlaybackMeterLocked()
            resetAudioPresentationLocked()
            externalAudioForLoad = source.externalAudioURL?.absoluteString
        }
        applyHTTPHeaders(source.httpHeaders)
        startPaused = !autostart
        pendingSeekAfterLoad = startTime

        // File opening on a sleeping/network disk must not wait on the UI thread.
        // libmpv copies argv before returning, preserving quotes and backslashes.
        setFlag(MPVProperty.pause, !autostart)
        let path = url.isFileURL ? url.path : url.absoluteString
        if !commandAsync("loadfile", args: [path, "replace"],
                         requestID: Self.loadCommandMask | loadGeneration) {
            error = "mpv rejected the request to load this file."
        }
    }

    func play() {
        if meterUsesHistory {
            queue.async { [weak self] in
                guard let self else { return }
                self.preparePlaybackMeterHistoryLocked()
                self.setFlag(MPVProperty.pause, false)
            }
        } else {
            setFlag(MPVProperty.pause, false)
        }
    }

    func pause() {
        startPaused = false
        playbackMeterSample = nil
        queue.async { [weak self] in self?.resetPlaybackMeterLocked() }
        setFlag(MPVProperty.pause, true)
    }

    func togglePause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        loadGeneration = (loadGeneration &+ 1) & ~Self.loadCommandMask
        pendingURL = nil
        pendingStartTime = 0
        pendingAutostart = false
        pendingSource = RemoteSource()
        pendingSeekAfterLoad = 0
        queue.sync {
            externalAudioForLoad = nil
            seekScheduler.reset()
            resetPlaybackMeterLocked()
            resetAudioPresentationLocked()
        }
        commandAsync("stop")
        isPlaying = false
        timePos = 0
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        var seekTime = time
        if duration > 0 {
            let maxSeekTime = max(0, duration - 0.05)
            seekTime = min(seekTime, maxSeekTime)
        }
        seekTime = max(0, seekTime)

        enqueueSeek(to: seekTime, exact: true)
    }

    /// Fast, keyframe-aligned seek for interactive timeline scrubbing.
    /// A precise seek is issued when the gesture ends.
    func seekForScrubbing(to time: TimeInterval) {
        guard time.isFinite else { return }
        var seekTime = time
        if duration > 0 {
            let maxSeekTime = max(0, duration - 0.05)
            seekTime = min(seekTime, maxSeekTime)
        }
        seekTime = max(0, seekTime)

        enqueueSeek(to: seekTime, exact: false)
    }

    /// Discard obsolete drag targets without interrupting a decoder that is
    /// already working. A final precise seek replaces the pending preview.
    func cancelPendingScrubSeeks() {
        queue.async { [weak self] in self?.seekScheduler.cancelPendingPreview() }
    }

    private func enqueueSeek(to time: Double, exact: Bool) {
        guard time.isFinite else { return }
        queue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            self.resetPlaybackMeterLocked()
            if self.meterUsesHistory { self.installPlaybackMeterFilterLocked() }
            // The user's seek replaces the redraw target; never undo it.
            self.audioPresentationRefresh?.target = nil
            if let submission = self.seekScheduler.request(.init(time: time, exact: exact)) {
                self.submitSeekLocked(submission)
            }
        }
    }

    /// All scheduler state and submissions share the event/teardown queue.
    private func submitSeekLocked(_ submission: MPVSeekScheduler.Submission) {
        guard let mpv else { return }
        let args = ["seek", String(submission.request.time),
                    submission.request.exact ? "absolute+exact" : "absolute+keyframes"]
        var cargs = args.map { strdup($0).map { UnsafePointer<CChar>($0) } }
        cargs.append(nil)
        defer { for ptr in cargs { if let ptr { free(UnsafeMutablePointer(mutating: ptr)) } } }
        // libmpv copies argv before returning. Completion arrives separately;
        // neither accepting the command nor dispatching it blocks the UI.
        let status = mpv_command_async(mpv, submission.id, &cargs)
        if status < 0 {
            logger.warning("Could not enqueue MPV seek: \(String(cString: mpv_error_string(status)))")
            if let next = seekScheduler.commandReplied(id: submission.id, succeeded: false) {
                submitSeekLocked(next)
            }
            completeAudioPresentationRefreshIfIdleLocked()
        }
    }

    /// Tells mpv the layer's drawableSize changed. mpv's MoltenVK context
    /// polls the size only while the video output runs; this resizes and
    /// redraws a paused or idle player immediately.
    func surfaceDidResize(to size: CGSize) {
        let value = "\(Int(size.width))x\(Int(size.height))"
        queue.async { [weak self] in
            guard let mpv = self?.mpv else { return }
            mpv_set_property_string(mpv, "moltenvk-surface-size", value)
        }
    }

    func seekRelative(_ time: TimeInterval) {
        commandAsync("seek", args: [String(time), "relative"])
    }

    // Keep the requested rate available immediately without a synchronous
    // readback that could wait on a network open (or an earlier async setter).
    private var playbackRate: Float = 1
    var rate: Float {
        get { playbackRate }
        set {
            playbackRate = newValue
            setDouble(MPVProperty.speed, Double(newValue))
        }
    }

    // MARK: - Audio Tracks

    var audioTrackNames: [String] {
        guard mpv != nil, isFileLoaded else { return [] }

        var names: [String] = []
        let count = getInt(MPVProperty.trackListCount)
        var audioIndex = 0

        for i in 0..<count {
            let typeKey = "track-list/\(i)/type"
            guard let type = getString(typeKey), type == "audio" else { continue }

            let titleKey = "track-list/\(i)/title"
            let langKey = "track-list/\(i)/lang"
            let codecKey = "track-list/\(i)/codec"
            let channelsKey = "track-list/\(i)/demux-channel-count"
            let sampleRateKey = "track-list/\(i)/demux-samplerate"

            // Build track name with available metadata
            var components: [String] = []

            // Track number
            components.append("#\(audioIndex)")
            audioIndex += 1

            // Language (always show if available)
            if let lang = getString(langKey), !lang.isEmpty {
                components.append(lang.uppercased())
            }

            // Title (if different from language)
            if let title = getString(titleKey), !title.isEmpty {
                let lang = getString(langKey) ?? ""
                if title.lowercased() != lang.lowercased() {
                    components.append(title)
                }
            }

            // Codec
            if let codec = getString(codecKey), !codec.isEmpty {
                components.append(codec.uppercased())
            }

            // Channel layout
            let channels = getInt(channelsKey)
            if channels > 0 {
                let channelDesc = formatChannelCount(channels)
                components.append(channelDesc)
            }

            // Sample rate
            let sampleRate = getInt(sampleRateKey)
            if sampleRate > 0 {
                components.append("\(sampleRate / 1000) kHz")
            }

            names.append(components.joined(separator: " • "))
        }

        return names
    }

    private func formatChannelCount(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(channels) ch"
        }
    }

    var audioTrackIndexes: [Int32] {
        guard mpv != nil, isFileLoaded else { return [] }

        var indexes: [Int32] = []
        let count = getInt(MPVProperty.trackListCount)

        for i in 0..<count {
            let typeKey = "track-list/\(i)/type"
            guard let type = getString(typeKey), type == "audio" else { continue }

            let idKey = "track-list/\(i)/id"
            let trackId = getInt(idKey)
            indexes.append(Int32(trackId))
        }

        return indexes
    }

    var currentAudioTrackIndex: Int32 {
        get {
            Int32(getInt(MPVProperty.aid))
        }
        set {
            playbackMeterSample = nil
            queue.async { [weak self] in self?.resetPlaybackMeterLocked() }
            setInt(MPVProperty.aid, Int(newValue))
        }
    }

    /// Inspect source programs using actual MPV IDs, preserving each mono input's gain.
    /// Pan assigns disjoint output channels before amix; the pinned library has no join filter.
    static var supportsGroupedAudioPresentation: Bool {
        ["pan", "amix"].allSatisfy { name in
            name.withCString { avfilter_get_by_name($0) != nil }
        }
    }

    private var audioPresentationOwnsSelection = false // Event queue only.
    private var audioPresentationRefresh: AudioPresentationRefresh? // Event queue only.

    private struct AudioPresentationRefresh {
        let id: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<Bool, Never>
        let deadline: DispatchWorkItem
        /// Where the redraw seek must land; nil once a user seek takes over.
        var target: Double?
        var retried = false
    }

    private func finishAudioPresentationRefreshLocked(id: UUID? = nil, succeeded: Bool) {
        guard let refresh = audioPresentationRefresh, id == nil || id == refresh.id else { return }
        audioPresentationRefresh = nil
        refresh.deadline.cancel()
        refresh.continuation.resume(returning: succeeded && refresh.generation == loadGeneration)
    }

    private func completeAudioPresentationRefreshIfIdleLocked() {
        guard seekScheduler.inFlight == nil, seekScheduler.pending == nil,
              let succeeded = seekScheduler.lastCompletionSucceeded else { return }
        // Switching `aid` makes the demuxer re-read the new stream. An exact
        // seek issued meanwhile can land on the next keyframe (seconds later
        // with sparse GOPs); once the switch has settled, a repeat is exact.
        if succeeded, var refresh = audioPresentationRefresh, let target = refresh.target,
           !refresh.retried, let mpv {
            var landed = target
            var fps = 0.0
            _ = mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &landed)
            _ = mpv_get_property(mpv, "container-fps", MPV_FORMAT_DOUBLE, &fps)
            // Exact seeks show the first frame at or after the target.
            let tolerance = fps > 0 ? max(0.05, 1.5 / fps) : 0.1
            if abs(landed - target) > tolerance {
                refresh.retried = true
                audioPresentationRefresh = refresh
                if let submission = seekScheduler.request(.init(time: target, exact: true)) {
                    submitSeekLocked(submission)
                }
                return
            }
        }
        finishAudioPresentationRefreshLocked(succeeded: succeeded)
    }

    private func resetAudioPresentationLocked() {
        finishAudioPresentationRefreshLocked(succeeded: false)
        guard audioPresentationOwnsSelection, let mpv else { return }
        _ = mpv_set_property_string(mpv, "lavfi-complex", "")
        _ = mpv_set_property_string(mpv, "aid", "auto")
        audioPresentationOwnsSelection = false
    }

    var audioPresentationFilterGraph: String? { getString("lavfi-complex") }

    static func audioPresentationGraph(_ presentation: LoudnessPresentation, trackIDs: [Int32]) -> String? {
        let indices = presentation.streamIndices
        guard !indices.isEmpty, Set(indices).count == indices.count,
              indices.allSatisfy({ trackIDs.indices.contains($0) && trackIDs[$0] > 0 }) else { return nil }
        let roles: [String]
        let layout: String
        switch presentation {
        case .track: return ""
        case .stereo: roles = ["FL", "FR"]; layout = "stereo"
        case .surround51:
            guard indices.count == 6 else { return nil }
            roles = ["FL", "FR", "FC", "LFE", "SL", "SR"]; layout = "5.1(side)"
        }
        let inputs = indices.enumerated().map { offset, index in
            let mapping = roles.map { "\($0)=\($0 == roles[offset] ? "c0" : "0*c0")" }.joined(separator: "|")
            return "[aid\(trackIDs[index])]pan=\(layout)|\(mapping)[amc_group_\(offset)]"
        }
        let pads = indices.indices.map { "[amc_group_\($0)]" }.joined()
        return inputs.joined(separator: ";") + ";" + pads
            + "amix=inputs=\(indices.count):duration=longest:dropout_transition=0:normalize=0[ao]"
    }

    /// Queue all changes together: older requests finish before newer requests, so
    /// a suspended caller can never apply its old selection after a newer one.
    @MainActor
    func selectAudioPresentation(_ presentation: LoudnessPresentation) async -> Bool {
        guard isFileLoaded, !Task.isCancelled else { return false }
        let trackIDs = audioTrackIndexes
        let graph = Self.audioPresentationGraph(presentation, trackIDs: trackIDs)
        let generation = loadGeneration
        playbackMeterSample = nil
        let cancellation = MPVPresentationCancellation()
        let succeeded = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    guard let self, let mpv = self.mpv, generation == self.loadGeneration,
                          !cancellation.isCancelled else {
                        continuation.resume(returning: false)
                        return
                    }
                    self.finishAudioPresentationRefreshLocked(succeeded: false)
                    self.resetPlaybackMeterLocked()
                    var actualPosition = 0.0
                    let positionStatus = mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &actualPosition)
                    // Preserve a seek the user has already requested instead of
                    // replacing it with an older published playback position.
                    let desiredPosition = self.seekScheduler.pending?.time
                        ?? self.seekScheduler.inFlight?.request.time ?? actualPosition
                    var seekable: Int32 = 0
                    _ = mpv_get_property(mpv, "seekable", MPV_FORMAT_FLAG, &seekable)
                    let refreshVideo = self.getInt("vid") > 0 && seekable != 0
                    self.audioPresentationOwnsSelection = true
                    var paused: Int32 = 1
                    _ = mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
                    // Clear the previous source before validation, so failed grouping
                    // cannot leave an unrelated track audible when playback resumes.
                    _ = mpv_set_property_string(mpv, "lavfi-complex", "")
                    _ = mpv_set_property_string(mpv, "aid", "no")
                    guard let graph,
                          graph.isEmpty || Self.supportsGroupedAudioPresentation else {
                        continuation.resume(returning: false)
                        return
                    }
                    if !graph.isEmpty {
                        let selectedIDs = Set(presentation.streamIndices.map { trackIDs[$0] })
                        let count = self.getInt(MPVProperty.trackListCount)
                        let monoIDs = (0..<count).compactMap { index -> Int32? in
                            guard self.getString("track-list/\(index)/type") == "audio",
                                  self.getInt("track-list/\(index)/demux-channel-count") == 1 else { return nil }
                            return Int32(self.getInt("track-list/\(index)/id"))
                        }
                        guard selectedIDs.isSubset(of: Set(monoIDs)) else {
                            continuation.resume(returning: false)
                            return
                        }
                    }
                    let status: Int32
                    if case .track(let index) = presentation {
                        status = mpv_set_property_string(mpv, "aid", String(trackIDs[index]))
                    } else {
                        status = mpv_set_property_string(mpv, "lavfi-complex", graph)
                    }
                    if status < 0 {
                        _ = mpv_set_property_string(mpv, "lavfi-complex", "")
                        _ = mpv_set_property_string(mpv, "aid", "no")
                    }
                    guard status >= 0, !cancellation.isCancelled else {
                        continuation.resume(returning: false)
                        return
                    }
                    guard refreshVideo else {
                        continuation.resume(returning: true)
                        return
                    }
                    guard positionStatus >= 0, desiredPosition.isFinite else {
                        continuation.resume(returning: false)
                        return
                    }
                    // Internal redraw must not apply the public navigation EOF
                    // margin: that would rewind valid frames near the video end.
                    let target = max(0, desiredPosition)
                    let deadline = DispatchWorkItem { [weak self] in
                        self?.finishAudioPresentationRefreshLocked(id: cancellation.id, succeeded: false)
                    }
                    self.audioPresentationRefresh = AudioPresentationRefresh(
                        id: cancellation.id, generation: generation, continuation: continuation,
                        deadline: deadline, target: target)
                    self.queue.asyncAfter(deadline: .now() + 15, execute: deadline)
                    // Audio graph changes can invalidate inter-frame decoder state.
                    // Readiness requires the exact refresh seek to decode a new frame,
                    // not just acceptance of the property change or seek command.
                    if let submission = self.seekScheduler.request(.init(time: target, exact: true)) {
                        self.submitSeekLocked(submission)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async { [weak self] in
                self?.finishAudioPresentationRefreshLocked(id: cancellation.id, succeeded: false)
            }
        }
        return succeeded && !Task.isCancelled && generation == loadGeneration
    }

    // MARK: - Subtitle Tracks

    var subtitleTrackNames: [String] {
        guard mpv != nil, isFileLoaded else { return [] }

        var names: [String] = []
        let count = getInt(MPVProperty.trackListCount)
        var subIndex = 0

        for i in 0..<count {
            let typeKey = "track-list/\(i)/type"
            guard let type = getString(typeKey), type == "sub" else { continue }

            let titleKey = "track-list/\(i)/title"
            let langKey = "track-list/\(i)/lang"
            let codecKey = "track-list/\(i)/codec"

            // Build track name with available metadata
            var components: [String] = []

            // Track number
            components.append("#\(subIndex)")
            subIndex += 1

            // Language (always show if available)
            if let lang = getString(langKey), !lang.isEmpty {
                components.append(lang.uppercased())
            }

            // Title (if different from language)
            if let title = getString(titleKey), !title.isEmpty {
                let lang = getString(langKey) ?? ""
                if title.lowercased() != lang.lowercased() {
                    components.append(title)
                }
            }

            // Codec
            if let codec = getString(codecKey), !codec.isEmpty {
                components.append(codec.uppercased())
            }

            names.append(components.joined(separator: " • "))
        }

        return names
    }

    var subtitleTrackIndexes: [Int32] {
        guard mpv != nil, isFileLoaded else { return [] }

        var indexes: [Int32] = []
        let count = getInt(MPVProperty.trackListCount)

        for i in 0..<count {
            let typeKey = "track-list/\(i)/type"
            guard let type = getString(typeKey), type == "sub" else { continue }

            let idKey = "track-list/\(i)/id"
            let trackId = getInt(idKey)
            indexes.append(Int32(trackId))
        }

        return indexes
    }

    var currentSubtitleTrackIndex: Int32 {
        get {
            Int32(getInt(MPVProperty.sid))
        }
        set {
            setInt(MPVProperty.sid, Int(newValue))
        }
    }

    var isSubtitleVisible: Bool {
        get {
            getInt(MPVProperty.subVisibility) != 0
        }
        set {
            setFlag(MPVProperty.subVisibility, newValue)
        }
    }

    /// Disables subtitle display (sets sid to 0)
    func disableSubtitles() {
        setInt(MPVProperty.sid, 0)
    }

    // MARK: - Event Handling

    private func readEvents() {
        queue.async { [weak self] in
            guard let self, self.mpv != nil else {
                self?.logger.debug("readEvents: self or mpv is nil, returning")
                return
            }

            while self.mpv != nil {
                let event = mpv_wait_event(self.mpv, 0)
                guard let pointee = event?.pointee else {
                    break
                }

                if pointee.event_id == MPV_EVENT_NONE {
                    break
                }

                switch pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    // Handle property change inline to avoid actor isolation issues
                    if let dataPtr = OpaquePointer(pointee.data),
                       let property = UnsafePointer<mpv_event_property>(dataPtr)?.pointee {
                        let propertyName = String(cString: property.name)

                    switch propertyName {
                        case MPVProperty.aid:
                            resetPlaybackMeterLocked()
                        case MPVProperty.timePos:
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                DispatchQueue.main.async { self.timePos = value }
                            }
                        case MPVProperty.duration:
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                DispatchQueue.main.async { self.duration = value }
                            }
                        case MPVProperty.pause:
                            if let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee {
                                if value != 0 { resetPlaybackMeterLocked() }
                                DispatchQueue.main.async { self.isPlaying = value == 0 }
                            }
                        case MPVProperty.pausedForCache:
                            if let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee {
                                DispatchQueue.main.async { self.isBusy = value != 0 }
                            }
                        case MPVProperty.seekable:
                            if let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee {
                                DispatchQueue.main.async { self.isSeekable = value != 0 }
                            }
                        case MPVProperty.eofReached:
                            if let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee {
                                let reached = value != 0
                                if reached { resetPlaybackMeterLocked() }
                                DispatchQueue.main.async {
                                    self.logger.info("EOF reached (\(reached)), pausing at last frame if needed")
                                    // Seeking away resets EOF for replay. A failed
                                    // or not-yet-loaded source cannot complete a clip.
                                    self.reachedEnd = reached && self.isFileLoaded && self.error == nil
                                    if reached {
                                        self.playbackMeterSample = nil
                                        self.isPlaying = false
                                    }
                                }
                            }
                        default:
                            break
                        }
                    }

                case MPV_EVENT_SEEK:
                    resetPlaybackMeterLocked(removeFilter: !meterUsesHistory)
                    seekScheduler.seekStarted()

                case MPV_EVENT_PLAYBACK_RESTART:
                    if let next = seekScheduler.playbackRestarted() {
                        submitSeekLocked(next)
                    }
                    completeAudioPresentationRefreshIfIdleLocked()

                case MPV_EVENT_COMMAND_REPLY:
                    if pointee.reply_userdata & Self.loadCommandMask != 0 {
                        let generation = pointee.reply_userdata & ~Self.loadCommandMask
                        let status = pointee.error
                        DispatchQueue.main.async {
                            self.handleLoadCommandReply(generation: generation, errorCode: status)
                        }
                        break
                    }
                    if let next = seekScheduler.commandReplied(
                        id: pointee.reply_userdata, succeeded: pointee.error >= 0
                    ) {
                        submitSeekLocked(next)
                    }
                    completeAudioPresentationRefreshIfIdleLocked()

                case MPV_EVENT_GET_PROPERTY_REPLY:
                    receivePlaybackMeterLocked(pointee)

                case MPV_EVENT_SET_PROPERTY_REPLY:
                    checkError(pointee.error)

                case MPV_EVENT_SHUTDOWN:
                    finishAudioPresentationRefreshLocked(succeeded: false)
                    seekScheduler.reset()
                    self.logger.info("MPV shutdown event")
                    if self.mpv != nil {
                        mpv_set_wakeup_callback(self.mpv, nil, nil)
                        mpv_terminate_destroy(self.mpv)
                        self.mpv = nil
                    }

                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(pointee.data)) {
                        let prefix = String(cString: msg.pointee.prefix!)
                        let level = String(cString: msg.pointee.level!)
                        let text = String(cString: msg.pointee.text!)
                        self.logger.debug("[\(prefix, privacy: .public)] \(level, privacy: .public): \(text.trimmingCharacters(in: .newlines), privacy: .public)")
                    }

                case MPV_EVENT_FILE_LOADED:
                    if let audio = self.externalAudioForLoad {
                        self.externalAudioForLoad = nil
                        self.commandAsync("audio-add", args: [audio, "select"])
                    }
                    // Replacing a playing source emits END_FILE without changing
                    // pause. Refresh the flag even when no pause notification follows.
                    var paused: Int32 = 1
                    let pauseStatus = mpv_get_property(self.mpv, MPVProperty.pause, MPV_FORMAT_FLAG, &paused)
                    let playing = pauseStatus >= 0 && paused == 0
                    DispatchQueue.main.async {
                        self.isPlaying = playing && !self.startPaused
                        let loadDuration = CFAbsoluteTimeGetCurrent() - self.loadStartTime
                        self.logger.info("⏱️ [\(String(format: "%.3f", loadDuration))s] MPV_EVENT_FILE_LOADED received")
                        self.isFileLoaded = true
                        // Seek to pending start time if set (workaround for loadfile start= issues)
                        if self.pendingSeekAfterLoad > 0 {
                            self.logger.info("⏱️ [\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - self.loadStartTime))s] Seeking to start time: \(self.pendingSeekAfterLoad)")
                            self.seek(to: self.pendingSeekAfterLoad)
                            self.logger.info("⏱️ [\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - self.loadStartTime))s] Seek command sent")
                            self.pendingSeekAfterLoad = 0
                        }
                        // If we requested paused start, ensure we're paused
                        if self.startPaused {
                            self.setFlag(MPVProperty.pause, true)
                            self.startPaused = false
                        }
                        self.logger.info("⏱️ [\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - self.loadStartTime))s] File load handling complete")
                    }

                case MPV_EVENT_END_FILE:
                    finishAudioPresentationRefreshLocked(succeeded: false)
                    resetPlaybackMeterLocked()
                    seekScheduler.reset()
                    if let dataPtr = OpaquePointer(pointee.data) {
                        let endFile = UnsafePointer<mpv_event_end_file>(dataPtr).pointee
                        DispatchQueue.main.async {
                            self.handleEndFile(reason: endFile.reason, errorCode: endFile.error)
                        }
                    }

                case MPV_EVENT_START_FILE:
                    let startElapsed = CFAbsoluteTimeGetCurrent() - self.loadStartTime
                    self.logger.info("⏱️ [\(String(format: "%.3f", startElapsed))s] MPV_EVENT_START_FILE received")

                default:
                    break
                }
            }
        }
    }

    // MARK: - MPV Commands & Properties

    /// Only natural EOF completes a clip. Stop/replacement and decoder failures
    /// also emit END_FILE and must never advance a stitching sequence.
    @MainActor
    func handleEndFile(reason: mpv_end_file_reason, errorCode: Int32) {
        isPlaying = false
        if reason == MPV_END_FILE_REASON_ERROR {
            let message = String(cString: mpv_error_string(errorCode))
            logger.error("MPV end file error: \(message)")
            isFileLoaded = false
            error = message
        }
        reachedEnd = reason == MPV_END_FILE_REASON_EOF && error == nil
    }

    /// Failed requests for a replaced/stopped source must not fail the current preview.
    @MainActor
    func handleLoadCommandReply(generation: UInt64, errorCode: Int32) {
        guard generation == loadGeneration, errorCode < 0 else { return }
        isFileLoaded = false
        error = "mpv could not load this file: \(String(cString: mpv_error_string(errorCode)))"
    }

    @discardableResult
    private func commandAsync(_ name: String, args: [String] = [], requestID: UInt64 = 0) -> Bool {
        guard let mpv else { return false }
        var cargs = ([name] + args).map { strdup($0).map { UnsafePointer<CChar>($0) } }
        cargs.append(nil)
        defer { for ptr in cargs { if let ptr { free(UnsafeMutablePointer(mutating: ptr)) } } }
        let status = mpv_command_async(mpv, requestID, &cargs)
        checkError(status)
        return status >= 0
    }

    /// Options apply to the next `loadfile`. Header values containing commas
    /// (Accept lists) would split mpv's comma-separated list and are left out;
    /// hosts check User-Agent and Referer, not those.
    private func applyHTTPHeaders(_ headers: [String: String]) {
        guard let mpv, !headers.isEmpty || hasCustomHTTPHeaders else { return }
        let userAgent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        let fields = headers
            .filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame && !$0.value.contains(",") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ",")
        checkError(mpv_set_property_string(mpv, "user-agent", userAgent ?? "libmpv"))
        checkError(mpv_set_property_string(mpv, "http-header-fields", fields))
        hasCustomHTTPHeaders = !headers.isEmpty
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var data = value
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_DOUBLE, &data)
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func setInt(_ name: String, _ value: Int) {
        guard mpv != nil else { return }
        var data = Int64(value)
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_INT64, &data)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        let cstr = mpv_get_property_string(mpv, name)
        defer { mpv_free(cstr) }
        return cstr == nil ? nil : String(cString: cstr!)
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard let mpvCtx = mpv else {
            logger.warning("setFlag called but mpv is nil")
            return
        }
        logger.info("setFlag: \(name) = \(flag)")
        // Use Int32 to match C's int type for MPV_FORMAT_FLAG
        var data: Int32 = flag ? 1 : 0
        let result = mpv_set_property_async(mpvCtx, 0, name, MPV_FORMAT_FLAG, &data)
        if result < 0 {
            logger.warning("setFlag failed: \(String(cString: mpv_error_string(result)))")
        }
        logger.info("setFlag completed")
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            let errorMsg = String(cString: mpv_error_string(status))
            logger.error("MPV API error: \(errorMsg)")
        }
    }
}

// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

/// Owned by MPVPlayer's event queue. Command acceptance alone does not mean
/// that the decoder has produced a frame: wait for seek + playback-restart.
struct MPVSeekScheduler {
    struct Request: Equatable {
        let time: Double
        let exact: Bool
    }

    struct Submission: Equatable {
        let id: UInt64
        let request: Request
    }

    private(set) var pending: Request?
    private(set) var inFlight: Submission?
    private(set) var lastCompletionSucceeded: Bool?
    private var nextID: UInt64 = 0
    private var accepted = false
    private var started = false
    private var restarted = false

    mutating func request(_ request: Request) -> Submission? {
        guard request.time.isFinite else { return nil }
        pending = request
        return takeNext()
    }

    mutating func commandReplied(id: UInt64, succeeded: Bool) -> Submission? {
        guard inFlight?.id == id else { return nil }
        if !succeeded { return finish(succeeded: false) }
        accepted = true
        return finishIfReady()
    }

    mutating func seekStarted() {
        guard inFlight != nil else { return }
        started = true
    }

    mutating func playbackRestarted() -> Submission? {
        // Ignore startup and other discontinuities preceding our seek event.
        guard inFlight != nil, started else { return nil }
        restarted = true
        return finishIfReady()
    }

    mutating func cancelPendingPreview() {
        if pending?.exact == false { pending = nil }
    }

    mutating func reset() {
        pending = nil
        inFlight = nil
        lastCompletionSucceeded = nil
        accepted = false
        started = false
        restarted = false
    }

    private mutating func finishIfReady() -> Submission? {
        guard accepted, restarted else { return nil }
        return finish(succeeded: true)
    }

    private mutating func finish(succeeded: Bool) -> Submission? {
        lastCompletionSucceeded = succeeded
        inFlight = nil
        return takeNext()
    }

    private mutating func takeNext() -> Submission? {
        guard inFlight == nil, let request = pending else { return nil }
        pending = nil
        nextID &+= 1
        let submission = Submission(id: nextID, request: request)
        inFlight = submission
        accepted = false
        started = false
        restarted = false
        return submission
    }
}

private extension Array where Element == String {
    func withUnsafeCStringArray<T>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> T) -> T {
        var pointers = map { strdup($0).map { UnsafePointer<CChar>($0) } }
        pointers.append(nil)
        defer { for pointer in pointers { if let pointer { free(UnsafeMutablePointer(mutating: pointer)) } } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

/// Cancellation can arrive before the event queue installs its readiness waiter.
private final class MPVPresentationCancellation: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
