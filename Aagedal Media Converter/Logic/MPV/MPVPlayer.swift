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
    private var handle: mpv_handle?
    private var renderContext: mpv_render_context?
    
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
        destroy()
    }
    
    private func create() {
        guard let handle = lib.mpv_create() else {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").error("Failed to create mpv handle")
            return
        }
        self.handle = handle
        
        // Configure basic options
        check(lib.mpv_set_option_string(handle, "vo", "libmpv"))
        check(lib.mpv_set_option_string(handle, "hwdec", "auto"))
        
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
        let path = url.path
        let cmd = ["loadfile", path]
        check(lib.mpv_command(handle, cmd))
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
    
    func seek(to time: Double) {
        guard let handle else { return }
        let cmd = ["seek", String(time), "absolute"]
        check(lib.mpv_command(handle, cmd))
    }
    
    // MARK: - Rendering
    
    func initRenderContext(getProcAddress: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?) {
        guard let handle else { return }
        
        var params = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: nil,
            extra_exts: nil
        )
        
        var renderParams: [mpv_render_param] = [
            mpv_render_param(type: LibMPV.MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: LibMPV.MPV_RENDER_API_TYPE_OPENGL)),
            mpv_render_param(type: LibMPV.MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: &params)
        ]
        
        var ctx: mpv_render_context?
        let res = lib.mpv_render_context_create(&ctx, handle, &renderParams)
        
        if res < 0 {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").error("Failed to create render context: \(res)")
            return
        }
        
        self.renderContext = ctx
        
        // Set update callback
        let callback: mpv_render_update_fn = { ctx in
            // This is called from a background thread usually
            DispatchQueue.main.async {
                // We need to notify the view to redraw
                // Since we can't easily pass self to the C callback without Unmanaged,
                // we'll use a global notification or similar mechanism, OR
                // we rely on the fact that we are setting the callback on the context
                // and we can pass 'self' as context data if we use Unmanaged.
                // For simplicity in this wrapper, let's use a notification for now
                NotificationCenter.default.post(name: .mpvRenderUpdate, object: nil)
            }
        }
        
        lib.mpv_render_context_set_update_callback(ctx, callback, nil)
    }
    
    func render(size: CGSize, fbo: Int32) {
        guard let ctx = renderContext else { return }
        
        var openglFbo = fbo_param(fbo: fbo, w: Int32(size.width), h: Int32(size.height), internal_format: 0)
        var params: [mpv_render_param] = [
            mpv_render_param(type: 4, data: &openglFbo), // MPV_RENDER_PARAM_OPENGL_FBO = 4
            mpv_render_param(type: LibMPV.MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(mutating: [Int32(1)].withUnsafeMutableBufferPointer { $0.baseAddress! }))
        ]
        
        lib.mpv_render_context_render(ctx, &params)
    }
    
    // MARK: - Private
    
    private struct fbo_param {
        var fbo: Int32
        var w: Int32
        var h: Int32
        var internal_format: Int32
    }
    
    private func check(_ result: Int32) {
        if result < 0 {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPV").error("MPV error: \(result)")
        }
    }
    
    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        check(lib.mpv_set_property_flag(handle, name, value))
    }
    
    private func startEventLoop() {
        guard let handle else { return }
        
        // Observe properties
        lib.mpv_observe_property(handle, 0, "time-pos", .double)
        lib.mpv_observe_property(handle, 0, "duration", .double)
        lib.mpv_observe_property(handle, 0, "pause", .flag)
        lib.mpv_observe_property(handle, 0, "seekable", .flag)
        lib.mpv_observe_property(handle, 0, "idle-active", .flag)
        
        eventLoopTask = Task.detached(priority: .userInitiated) { [weak self, lib, handle] in
            while !Task.isCancelled {
                guard let eventPtr = lib.mpv_wait_event(handle, 1.0) else { continue }
                let event = eventPtr.pointee
                
                if event.event_id == .none { continue }
                
                await self?.handleEvent(event)
            }
        }
    }
    
    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case .propertyChange:
            guard let propPtr = event.data?.assumingMemoryBound(to: mpv_event_property.self) else { return }
            let prop = propPtr.pointee
            let name = String(cString: prop.name)
            
            switch name {
            case "time-pos":
                if prop.format == .double, let value = prop.data?.assumingMemoryBound(to: Double.self).pointee {
                    self.timePos = value
                }
            case "duration":
                if prop.format == .double, let value = prop.data?.assumingMemoryBound(to: Double.self).pointee {
                    self.duration = value
                }
            case "pause":
                if prop.format == .flag, let value = prop.data?.assumingMemoryBound(to: Int32.self).pointee {
                    self.isPlaying = value == 0
                }
            case "seekable":
                if prop.format == .flag, let value = prop.data?.assumingMemoryBound(to: Int32.self).pointee {
                    self.isSeekable = value == 1
                }
            default:
                break
            }
        case .endFile:
            if event.error < 0 {
                self.error = "Playback error"
            }
        default:
            break
        }
    }
}

extension Notification.Name {
    static let mpvRenderUpdate = Notification.Name("mpvRenderUpdate")
}
