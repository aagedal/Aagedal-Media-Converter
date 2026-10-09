// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import AppKit
import Libmpv
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

    private var isInitialized = false
    private var startPaused = false
    private var wakeupContext: UnsafeMutableRawPointer?

    // Pending load - stored when load() is called before MPV is initialized
    private var pendingURL: URL?
    private var pendingStartTime: Double = 0
    private var pendingAutostart: Bool = false
    private(set) var loadGeneration: UInt64 = 0
    private static let loadCommandMask: UInt64 = 1 << 63

    // Start time to seek to after file loads (workaround for loadfile start= parsing issue)
    private var pendingSeekAfterLoad: Double = 0

    override init() {
        super.init()
        queue.setSpecific(key: eventQueueKey, value: true)
    }

    deinit {
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
        metalLayer = layer
        setupMPV()

        // Process pending load if any
        if let url = pendingURL {
            let startTime = pendingStartTime
            let autostart = pendingAutostart
            pendingURL = nil
            pendingStartTime = 0
            pendingAutostart = false
            load(url: url, startTime: startTime, autostart: autostart)
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

    func load(url: URL, startTime: Double = 0, autostart: Bool = false) {
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
            return
        }

        queue.sync { seekScheduler.reset() }
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
        setFlag(MPVProperty.pause, false)
    }

    func pause() {
        startPaused = false
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
        pendingSeekAfterLoad = 0
        queue.sync { seekScheduler.reset() }
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
            setInt(MPVProperty.aid, Int(newValue))
        }
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
                                DispatchQueue.main.async {
                                    self.logger.info("EOF reached (\(reached)), pausing at last frame if needed")
                                    // Seeking away resets EOF for replay. A failed
                                    // or not-yet-loaded source cannot complete a clip.
                                    self.reachedEnd = reached && self.isFileLoaded && self.error == nil
                                    if reached {
                                        self.isPlaying = false
                                    }
                                }
                            }
                        default:
                            break
                        }
                    }

                case MPV_EVENT_SEEK:
                    seekScheduler.seekStarted()

                case MPV_EVENT_PLAYBACK_RESTART:
                    if let next = seekScheduler.playbackRestarted() {
                        submitSeekLocked(next)
                    }

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

                case MPV_EVENT_SET_PROPERTY_REPLY:
                    checkError(pointee.error)

                case MPV_EVENT_SHUTDOWN:
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
                    DispatchQueue.main.async {
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
        if !succeeded { return finish() }
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
        accepted = false
        started = false
        restarted = false
    }

    private mutating func finishIfReady() -> Submission? {
        guard accepted, restarted else { return nil }
        return finish()
    }

    private mutating func finish() -> Submission? {
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
