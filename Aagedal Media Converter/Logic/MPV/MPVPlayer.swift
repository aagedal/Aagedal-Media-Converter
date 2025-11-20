// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import AppKit
import OSLog

@MainActor
final class MPVPlayer: ObservableObject {
    private let lib = LibMPV.shared
    nonisolated(unsafe) private var handle: mpv_handle?
    nonisolated(unsafe) private var renderContext: mpv_render_context?
    
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var timePos: Double = 0
    @Published var volume: Double = 100
    @Published var isSeekable = false
    @Published var isBusy = false
    @Published var error: String?
    
    private var eventLoopTask: Task<Void, Never>?
    private var renderContextUpdateHandler: (() -> Void)?
    
    init() {
        create()
    }
    
    deinit {
        eventLoopTask?.cancel()
        if let ctx = renderContext {
            LibMPV.shared.mpv_render_context_free(ctx)
        }
        if let h = handle {
            LibMPV.shared.mpv_terminate_destroy(h)
        }
    }
    
    private func create() {
        guard let handle = lib.mpv_create() else {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").error("Failed to create mpv handle")
            return
        }
        self.handle = handle
        
        // Configure basic options
        check(lib.mpv_set_option_string(handle, "vo", "libmpv"), context: "set vo=libmpv")
        check(lib.mpv_set_option_string(handle, "hwdec", "auto"), context: "set hwdec=auto")
        check(lib.mpv_set_option_string(handle, "pause", "yes"), context: "set pause=yes")
        
        // Initialize
        let initResult = lib.mpv_initialize(handle)
        if initResult < 0 {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").error("Failed to initialize mpv: \(initResult)")
            return
        }
        
        startEventLoop()
    }
    
    func destroy() {
        eventLoopTask?.cancel()
        if let ctx = renderContext {
            lib.mpv_render_context_free(ctx)
            renderContext = nil
        }
        if let h = handle {
            lib.mpv_terminate_destroy(h)
            handle = nil
        }
    }
    
    func load(url: URL) {
        guard let handle else { return }
        isReady = false
        pendingSeekTime = nil
        
        let path = url.path
        Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").info("Loading path: \(path)")
        
        // Use command_string to avoid array marshalling issues
        // Quote the path to be safe
        let cmd = "loadfile \"\(path)\""
        check(lib.mpv_command_string(handle, cmd), context: "loadfile")
    }
    
    func play() {
        setFlag("pause", false)
    }
    
    func pause() {
        setFlag("pause", true)
    }
    
    func togglePause() {
        guard let handle else { return }
        if let paused = lib.mpv_get_property_string(handle, "pause") {
            let isPaused = paused == "yes"
            setFlag("pause", !isPaused)
        }
    }
    
    private var isReady = false
    private var pendingSeekTime: Double?
    
    func seek(to time: Double) {
        guard let handle else { return }
        
        if !isReady {
            pendingSeekTime = time
            return
        }
        
        let cmd = "seek \(time) absolute"
        check(lib.mpv_command_string(handle, cmd), context: "seek")
    }
    
    // MARK: - Rendering
    
    // MARK: - Rendering
    
    nonisolated func initRenderContext(getProcAddress: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?) {
        guard let handle else { return }
        
        var params = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: nil,
            extra_exts: nil
        )
        
        withUnsafeMutablePointer(to: &params) { paramsPtr in
            (LibMPV.MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String!.withMemoryRebound(to: CChar.self, capacity: 1) { apiTypePtr in
                var renderParams: [mpv_render_param] = [
                    mpv_render_param(type: LibMPV.MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiTypePtr)),
                    mpv_render_param(type: LibMPV.MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(paramsPtr)),
                    mpv_render_param(type: 0, data: nil) // Null terminator
                ]
                
                var ctx: mpv_render_context?
                let res = lib.mpv_render_context_create(&ctx, handle, &renderParams)
                
                if res < 0 {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").error("Failed to create render context: \(res)")
                    return
                }
                
                self.renderContext = ctx
            }
        }
        
        guard let ctx = renderContext else { return }
        
        // Set update callback
        let callback: mpv_render_update_fn = { ctx in
            // This is called from a background thread usually
            DispatchQueue.main.async {
                // We need to notify the view to redraw
                NotificationCenter.default.post(name: .mpvRenderUpdate, object: nil)
            }
        }
        
        lib.mpv_render_context_set_update_callback(ctx, callback, nil)
    }
    
    nonisolated func render(size: CGSize, fbo: Int32) {
        guard let ctx = renderContext else { return }
        
        var openglFbo = fbo_param(fbo: fbo, w: Int32(size.width), h: Int32(size.height), internal_format: 0)
        var flipY: Int32 = 1
        
        withUnsafeMutablePointer(to: &openglFbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipYPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: 4, data: UnsafeMutableRawPointer(fboPtr)), // MPV_RENDER_PARAM_OPENGL_FBO = 4
                    mpv_render_param(type: LibMPV.MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipYPtr)),
                    mpv_render_param(type: 0, data: nil) // Null terminator
                ]
                
                let result = lib.mpv_render_context_render(ctx, &params)
                if result < 0 {
                     Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").error("Render failed: \(result)")
                }
            }
        }
    }
    
    // MARK: - Private
    
    private struct fbo_param {
        var fbo: Int32
        var w: Int32
        var h: Int32
        var internal_format: Int32
    }
    
    private func check(_ result: Int32, context: String = "") {
        if result < 0 {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").error("MPV error (\(context)): \(result)")
        }
    }
    
    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        check(lib.mpv_set_property_flag(handle, name, value), context: "setFlag \(name)")
    }
    
    private func startEventLoop() {
        guard let handle else { return }
        
        // Observe properties
        _ = lib.mpv_observe_property(handle, 0, "time-pos", .double)
        _ = lib.mpv_observe_property(handle, 0, "duration", .double)
        _ = lib.mpv_observe_property(handle, 0, "pause", .flag)
        _ = lib.mpv_observe_property(handle, 0, "seekable", .flag)
        _ = lib.mpv_observe_property(handle, 0, "idle-active", .flag)
        
        let handleAddr = Int(bitPattern: handle)
        
        eventLoopTask = Task.detached(priority: .userInitiated) { @Sendable [weak self, lib] in
            guard let handle = mpv_handle(bitPattern: handleAddr) else { return }
            
            while !Task.isCancelled {
                guard let eventPtr = lib.mpv_wait_event(handle, 1.0) else { continue }
                let event = eventPtr.pointee
                
                guard event.event_id != 0 else { continue } // .none = 0
                guard let eventId = mpv_event_id(rawValue: event.event_id) else { continue }
                
                // Process event data in nonisolated context
                switch eventId {
                case .propertyChange:
                    guard let propPtr = event.data?.assumingMemoryBound(to: mpv_event_property.self) else { continue }
                    let prop = propPtr.pointee
                    let name = String(cString: prop.name)
                    
                    switch name {
                    case "time-pos":
                        if prop.format == .double, let data = prop.data {
                            let value = data.assumingMemoryBound(to: Double.self).pointee
                            await MainActor.run { [weak self] in
                                self?.timePos = value
                            }
                        }
                    case "duration":
                        if prop.format == .double, let data = prop.data {
                            let value = data.assumingMemoryBound(to: Double.self).pointee
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                self.duration = value
                                if value > 0 && !self.isReady {
                                    self.isReady = true
                                    if let seekTime = self.pendingSeekTime {
                                        self.seek(to: seekTime)
                                        self.pendingSeekTime = nil
                                    }
                                }
                            }
                        }
                    case "pause":
                        if prop.format == .flag, let data = prop.data {
                            let value = data.assumingMemoryBound(to: Int32.self).pointee
                            await MainActor.run { [weak self] in
                                self?.isPlaying = value == 0
                            }
                        }
                    case "seekable":
                        if prop.format == .flag, let data = prop.data {
                            let value = data.assumingMemoryBound(to: Int32.self).pointee
                            await MainActor.run { [weak self] in
                                self?.isSeekable = value == 1
                            }
                        }
                    default:
                        break
                    }
                case .endFile:
                    if event.error < 0 {
                        await MainActor.run { [weak self] in
                            self?.error = "Playback error"
                        }
                    }
                default:
                    break
                }
            }
        }
    }
    
}

extension Notification.Name {
    static let mpvRenderUpdate = Notification.Name("mpvRenderUpdate")
}
