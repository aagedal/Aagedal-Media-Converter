// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import AppKit
import Libmpv
import OSLog

/// MPV Player - NOT an actor to allow background thread access for event handling
/// All @Published property updates are dispatched to main thread
/// Marked @unchecked Sendable because we handle thread safety manually with DispatchQueue
final class MPVPlayer: NSObject, ObservableObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVPlayer")

    // MPV context
    private var mpv: OpaquePointer?
    private var metalLayer: MPVMetalLayer?
    private let queue = DispatchQueue(label: "com.aagedal.mpv", qos: .userInitiated)

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

    private var isInitialized = false
    private var startPaused = false
    private var wakeupContext: UnsafeMutableRawPointer?

    // Pending load - stored when load() is called before MPV is initialized
    private var pendingURL: URL?
    private var pendingStartTime: Double = 0
    private var pendingAutostart: Bool = false

    // Start time to seek to after file loads (workaround for loadfile start= parsing issue)
    private var pendingSeekAfterLoad: Double = 0

    override init() {
        super.init()
    }

    deinit {
        // Clean up MPV context
        if mpv != nil {
            mpv_set_wakeup_callback(mpv, nil, nil)

            queue.sync {
                if self.mpv != nil {
                    mpv_terminate_destroy(self.mpv)
                    self.mpv = nil
                }
            }
        }

        // Release the retained reference from the wakeup callback
        if let ctx = wakeupContext {
            Unmanaged<MPVPlayer>.fromOpaque(ctx).release()
            wakeupContext = nil
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

        // Register property observers
        mpv_observe_property(mpv, 0, MPVProperty.timePos, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.duration, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.pause, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.seekable, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.eofReached, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.speed, MPV_FORMAT_DOUBLE)

        // Set wakeup callback for event handling
        // Store the context so we can release it in deinit
        wakeupContext = Unmanaged.passRetained(self).toOpaque()
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let client = ctx else { return }
            let player = Unmanaged<MPVPlayer>.fromOpaque(client).takeUnretainedValue()
            player.readEvents()
        }, wakeupContext)

        isInitialized = true
        let setupDuration = CFAbsoluteTimeGetCurrent() - setupStart
        logger.info("⏱️ MPV initialized successfully in \(String(format: "%.3f", setupDuration))s")
    }

    // MARK: - Playback Control

    private var loadStartTime: CFAbsoluteTime = 0

    func load(url: URL, startTime: Double = 0, autostart: Bool = false) {
        loadStartTime = CFAbsoluteTimeGetCurrent()
        logger.info("⏱️ [0.000s] Load starting for: \(url.lastPathComponent)")

        // If MPV not initialized yet, store for later
        guard mpv != nil else {
            logger.info("⏱️ MPV not initialized yet, storing pending load for: \(url.lastPathComponent)")
            pendingURL = url
            pendingStartTime = startTime
            pendingAutostart = autostart
            return
        }

        // Reset file loaded state when loading a new file
        isFileLoaded = false

        // Reset EOF tracking for the new file
        reachedEnd = false

        var elapsed = CFAbsoluteTimeGetCurrent() - loadStartTime
        logger.info("⏱️ [\(String(format: "%.3f", elapsed))s] Preparing loadfile command...")

        startPaused = !autostart
        // Store start time to seek after file loads (loadfile start= has parsing issues with floats)
        pendingSeekAfterLoad = startTime

        // Use commandString for simpler execution - escaping the path for the command parser
        // For local files, use the path; for remote, use the URL
        let path = url.isFileURL ? url.path : url.absoluteString

        // Build command string with proper escaping (don't use start= option, seek after load instead)
        let cmd = "loadfile \"\(path.replacingOccurrences(of: "\"", with: "\\\""))\" replace"

        elapsed = CFAbsoluteTimeGetCurrent() - loadStartTime
        logger.info("⏱️ [\(String(format: "%.3f", elapsed))s] Executing loadfile...")
        commandString(cmd)
        elapsed = CFAbsoluteTimeGetCurrent() - loadStartTime
        logger.info("⏱️ [\(String(format: "%.3f", elapsed))s] Loadfile command returned")

        // If not autostarting, pause immediately after load
        if !autostart {
            setFlag(MPVProperty.pause, true)
        }
        elapsed = CFAbsoluteTimeGetCurrent() - loadStartTime
        logger.info("⏱️ [\(String(format: "%.3f", elapsed))s] Load function completed (async file loading continues)")
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
        command("stop")
        isPlaying = false
        timePos = 0
    }

    func seek(to time: TimeInterval) {
        // Clamp seek time to avoid EOF issues
        // If seeking near or beyond end, clamp to slightly before end
        var seekTime = time
        if duration > 0 {
            let maxSeekTime = max(0, duration - 0.05)  // Stay 50ms before end
            seekTime = min(seekTime, maxSeekTime)
        }
        seekTime = max(0, seekTime)  // Don't seek before start

        command("seek", args: [String(seekTime), "absolute"])
    }

    func seekRelative(_ time: TimeInterval) {
        command("seek", args: [String(time), "relative"])
    }

    var rate: Float {
        get {
            Float(getDouble(MPVProperty.speed))
        }
        set {
            setDouble(MPVProperty.speed, Double(newValue))
        }
    }

    // MARK: - Audio Tracks

    var audioTrackNames: [String] {
        guard mpv != nil else { return [] }

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
        guard mpv != nil else { return [] }

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
        guard mpv != nil else { return [] }

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
        guard mpv != nil else { return [] }

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
                            if let value = UnsafePointer<Int>(OpaquePointer(property.data))?.pointee {
                                DispatchQueue.main.async { self.isPlaying = value == 0 }
                            }
                        case MPVProperty.pausedForCache:
                            if let value = UnsafePointer<Int>(OpaquePointer(property.data))?.pointee {
                                DispatchQueue.main.async { self.isBusy = value != 0 }
                            }
                        case MPVProperty.seekable:
                            if let value = UnsafePointer<Int>(OpaquePointer(property.data))?.pointee {
                                DispatchQueue.main.async { self.isSeekable = value != 0 }
                            }
                        case MPVProperty.eofReached:
                            if let value = UnsafePointer<Int>(OpaquePointer(property.data))?.pointee {
                                let reached = value != 0
                                DispatchQueue.main.async {
                                    self.logger.info("EOF reached (\(reached)), pausing at last frame if needed")
                                    // Always update reachedEnd to match MPV's state
                                    // This ensures the observer can fire again after seeking away from EOF
                                    self.reachedEnd = reached
                                    if reached {
                                        self.isPlaying = false
                                    }
                                }
                            }
                        default:
                            break
                        }
                    }

                case MPV_EVENT_SHUTDOWN:
                    self.logger.info("MPV shutdown event")
                    if self.mpv != nil {
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
                    if let dataPtr = OpaquePointer(pointee.data) {
                        let endFile = UnsafePointer<mpv_event_end_file>(dataPtr).pointee
                        if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errorMsg = String(cString: mpv_error_string(endFile.error))
                            self.logger.error("MPV end file error: \(errorMsg)")
                            DispatchQueue.main.async {
                                self.error = errorMsg
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        self.isPlaying = false
                        self.reachedEnd = true
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

    /// Execute a command using mpv_command_string - simpler than mpv_command
    private func commandString(_ cmd: String) {
        guard let mpvCtx = mpv else { return }

        logger.info("Executing command string: \(cmd)")
        let result = mpv_command_string(mpvCtx, cmd)

        if result < 0 {
            logger.warning("MPV command failed: \(String(cString: mpv_error_string(result)))")
        } else {
            logger.info("MPV command succeeded")
        }
    }

    /// Execute a command with arguments using mpv_command
    private func command(_ name: String, args: [String] = []) {
        guard let mpvCtx = mpv else { return }

        // Build args array with command, arguments, and nil terminator
        var strArgs: [String?] = [name] + args
        strArgs.append(nil)

        // Convert to C strings - matching the MPVKit demo/IINA approach
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }

        logger.info("Executing command: \(name) with \(args.count) args")
        let result = mpv_command(mpvCtx, &cargs)

        if result < 0 {
            logger.warning("MPV command '\(name)' failed: \(String(cString: mpv_error_string(result)))")
        } else {
            logger.info("MPV command '\(name)' succeeded")
        }
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0.0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
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
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data)
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
        let result = mpv_set_property(mpvCtx, name, MPV_FORMAT_FLAG, &data)
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
