// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

// MARK: - LibMPV Types

typealias mpv_handle = OpaquePointer
typealias mpv_render_context = OpaquePointer

enum mpv_format: Int32 {
    case none = 0
    case string = 1
    case osdString = 2
    case flag = 3
    case int64 = 4
    case double = 5
    case node = 6
    case nodeId = 7
    case byteArray = 8
}

enum mpv_event_id: Int32 {
    case none = 0
    case shutdown = 1
    case logMessage = 2
    case getPropertyReply = 3
    case setPropertyReply = 4
    case commandReply = 5
    case startFile = 6
    case endFile = 7
    case fileLoaded = 8
    case idle = 11
    case tick = 14
    case clientMessage = 16
    case videoReconfig = 17
    case audioReconfig = 18
    case seek = 20
    case playbackRestart = 21
    case propertyChange = 22
    case queueOverflow = 24
    case hook = 25
}

struct mpv_event {
    var event_id: mpv_event_id
    var error: Int32
    var reply_userdata: UInt64
    var data: UnsafeMutableRawPointer?
}

struct mpv_render_param {
    var type: Int32
    var data: UnsafeMutableRawPointer?
}

typealias mpv_render_update_fn = @convention(c) (UnsafeMutableRawPointer?) -> Void

struct mpv_opengl_init_params {
    var get_proc_address: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    var get_proc_address_ctx: UnsafeMutableRawPointer?
    var extra_exts: UnsafePointer<CChar>?
}

// MARK: - LibMPV Wrapper

final class LibMPV {
    static let shared = LibMPV()
    private var handle: UnsafeMutableRawPointer?
    
    // Function pointers
    private var _mpv_create: @convention(c) () -> mpv_handle?
    private var _mpv_initialize: @convention(c) (mpv_handle?) -> Int32
    private var _mpv_destroy: @convention(c) (mpv_handle?) -> Void
    private var _mpv_terminate_destroy: @convention(c) (mpv_handle?) -> Void
    private var _mpv_command: @convention(c) (mpv_handle?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    private var _mpv_command_string: @convention(c) (mpv_handle?, UnsafePointer<CChar>?) -> Int32
    private var _mpv_free: @convention(c) (UnsafeMutableRawPointer?) -> Void
    private var _mpv_set_option: @convention(c) (mpv_handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    private var _mpv_set_option_string: @convention(c) (mpv_handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private var _mpv_get_property: @convention(c) (mpv_handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    private var _mpv_set_property: @convention(c) (mpv_handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    private var _mpv_observe_property: @convention(c) (mpv_handle?, UInt64, UnsafePointer<CChar>?, mpv_format) -> Int32
    private var _mpv_wait_event: @convention(c) (mpv_handle?, Double) -> UnsafeMutablePointer<mpv_event>?
    private var _mpv_render_context_create: @convention(c) (UnsafeMutablePointer<mpv_render_context?>?, mpv_handle?, UnsafeMutablePointer<mpv_render_param>?) -> Int32
    private var _mpv_render_context_free: @convention(c) (mpv_render_context?) -> Void
    private var _mpv_render_context_set_parameter: @convention(c) (mpv_render_context?, Int32, UnsafeMutableRawPointer?) -> Int32
    private var _mpv_render_context_get_info: @convention(c) (mpv_render_context?, Int32, UnsafeMutableRawPointer?) -> Int32
    private var _mpv_render_context_set_update_callback: @convention(c) (mpv_render_context?, mpv_render_update_fn?, UnsafeMutableRawPointer?) -> Void
    private var _mpv_render_context_update: @convention(c) (mpv_render_context?) -> Void
    private var _mpv_render_context_report_swap: @convention(c) (mpv_render_context?) -> Void
    private var _mpv_render_context_render: @convention(c) (mpv_render_context?, UnsafeMutablePointer<mpv_render_param>?) -> Int32
    
    // Render param constants (from mpv/render.h)
    static let MPV_RENDER_PARAM_API_TYPE = 1
    static let MPV_RENDER_PARAM_OPENGL_INIT_PARAMS = 2
    static let MPV_RENDER_PARAM_FLIP_Y = 3
    static let MPV_RENDER_API_TYPE_OPENGL = "opengl"
    
    private init() {
        // Locate libmpv.dylib in the bundle
        guard let bundlePath = Bundle.main.resourcePath else {
            fatalError("Could not find bundle resource path")
        }
        
        // We look in Binaries folder first, then Frameworks, then Resources
        let paths = [
            bundlePath + "/Binaries/libmpv.dylib",
            bundlePath + "/Frameworks/libmpv.dylib",
            bundlePath + "/libmpv.dylib"
        ]
        
        var loadedHandle: UnsafeMutableRawPointer? = nil
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                loadedHandle = dlopen(path, RTLD_NOW)
                if loadedHandle != nil {
                    print("Loaded libmpv from \(path)")
                    break
                }
            }
        }
        
        if loadedHandle == nil {
            // Fallback to trying to load from standard locations or if it's already linked
            loadedHandle = dlopen("libmpv.dylib", RTLD_NOW)
        }
        
        guard let handle = loadedHandle else {
            fatalError("Failed to load libmpv.dylib. Please ensure it is placed in the Binaries folder.")
        }
        
        self.handle = handle
        
        // Load symbols
        func load<T>(_ name: String) -> T {
            guard let sym = dlsym(handle, name) else {
                fatalError("Failed to load symbol \(name)")
            }
            return unsafeBitCast(sym, to: T.self)
        }
        
        _mpv_create = load("mpv_create")
        _mpv_initialize = load("mpv_initialize")
        _mpv_destroy = load("mpv_destroy")
        _mpv_terminate_destroy = load("mpv_terminate_destroy")
        _mpv_command = load("mpv_command")
        _mpv_command_string = load("mpv_command_string")
        _mpv_free = load("mpv_free")
        _mpv_set_option = load("mpv_set_option")
        _mpv_set_option_string = load("mpv_set_option_string")
        _mpv_get_property = load("mpv_get_property")
        _mpv_set_property = load("mpv_set_property")
        _mpv_observe_property = load("mpv_observe_property")
        _mpv_wait_event = load("mpv_wait_event")
        _mpv_render_context_create = load("mpv_render_context_create")
        _mpv_render_context_free = load("mpv_render_context_free")
        _mpv_render_context_set_parameter = load("mpv_render_context_set_parameter")
        _mpv_render_context_get_info = load("mpv_render_context_get_info")
        _mpv_render_context_set_update_callback = load("mpv_render_context_set_update_callback")
        _mpv_render_context_update = load("mpv_render_context_update")
        _mpv_render_context_report_swap = load("mpv_render_context_report_swap")
        _mpv_render_context_render = load("mpv_render_context_render")
    }
    
    // MARK: - API Wrappers
    
    func mpv_create() -> mpv_handle? { _mpv_create() }
    func mpv_initialize(_ ctx: mpv_handle?) -> Int32 { _mpv_initialize(ctx) }
    func mpv_destroy(_ ctx: mpv_handle?) { _mpv_destroy(ctx) }
    func mpv_terminate_destroy(_ ctx: mpv_handle?) { _mpv_terminate_destroy(ctx) }
    
    func mpv_command(_ ctx: mpv_handle?, _ args: [String]) -> Int32 {
        var cArgs = args.map { $0.withCString { UnsafePointer<CChar>(strdup($0)) } }
        cArgs.append(nil)
        defer { cArgs.forEach { free(UnsafeMutableRawPointer(mutating: $0)) } }
        return cArgs.withUnsafeMutableBufferPointer { ptr in
            _mpv_command(ctx, ptr.baseAddress)
        }
    }
    
    func mpv_command_string(_ ctx: mpv_handle?, _ args: String) -> Int32 {
        _mpv_command_string(ctx, args)
    }
    
    func mpv_set_option_string(_ ctx: mpv_handle?, _ name: String, _ value: String) -> Int32 {
        _mpv_set_option_string(ctx, name, value)
    }
    
    func mpv_get_property_double(_ ctx: mpv_handle?, _ name: String) -> Double? {
        var value: Double = 0
        let result = _mpv_get_property(ctx, name, .double, &value)
        return result >= 0 ? value : nil
    }
    
    func mpv_get_property_string(_ ctx: mpv_handle?, _ name: String) -> String? {
        var value: UnsafeMutablePointer<CChar>?
        let result = _mpv_get_property(ctx, name, .string, &value)
        guard result >= 0, let cStr = value else { return nil }
        let str = String(cString: cStr)
        _mpv_free(cStr)
        return str
    }
    
    func mpv_set_property_double(_ ctx: mpv_handle?, _ name: String, _ value: Double) -> Int32 {
        var v = value
        return _mpv_set_property(ctx, name, .double, &v)
    }
    
    func mpv_set_property_flag(_ ctx: mpv_handle?, _ name: String, _ value: Bool) -> Int32 {
        var v: Int32 = value ? 1 : 0
        return _mpv_set_property(ctx, name, .flag, &v)
    }
    
    func mpv_observe_property(_ ctx: mpv_handle?, _ reply_userdata: UInt64, _ name: String, _ format: mpv_format) -> Int32 {
        _mpv_observe_property(ctx, reply_userdata, name, format)
    }
    
    func mpv_wait_event(_ ctx: mpv_handle?, _ timeout: Double) -> UnsafeMutablePointer<mpv_event>? {
        _mpv_wait_event(ctx, timeout)
    }
    
    func mpv_render_context_create(_ res: inout mpv_render_context?, _ ctx: mpv_handle?, _ params: inout [mpv_render_param]) -> Int32 {
        var ptr = res
        var terminatedParams = params
        terminatedParams.append(mpv_render_param(type: 0, data: nil))
        
        let ret = terminatedParams.withUnsafeMutableBufferPointer { buffer in
            _mpv_render_context_create(&ptr, ctx, buffer.baseAddress)
        }
        res = ptr
        return ret
    }
    
    func mpv_render_context_free(_ ctx: mpv_render_context?) {
        _mpv_render_context_free(ctx)
    }
    
    func mpv_render_context_set_parameter(_ ctx: mpv_render_context?, _ param: Int32, _ data: UnsafeMutableRawPointer?) -> Int32 {
        _mpv_render_context_set_parameter(ctx, param, data)
    }
    
    func mpv_render_context_get_info(_ ctx: mpv_render_context?, _ param: Int32, _ data: UnsafeMutableRawPointer?) -> Int32 {
        _mpv_render_context_get_info(ctx, param, data)
    }
    
    func mpv_render_context_set_update_callback(_ ctx: mpv_render_context?, _ callback: mpv_render_update_fn?, _ data: UnsafeMutableRawPointer?) {
        _mpv_render_context_set_update_callback(ctx, callback, data)
    }
    
    func mpv_render_context_update(_ ctx: mpv_render_context?) {
        _mpv_render_context_update(ctx)
    }
    
    func mpv_render_context_render(_ ctx: mpv_render_context?, _ params: inout [mpv_render_param]) -> Int32 {
        var terminatedParams = params
        terminatedParams.append(mpv_render_param(type: 0, data: nil))
        return terminatedParams.withUnsafeMutableBufferPointer { buffer in
            _mpv_render_context_render(ctx, buffer.baseAddress)
        }
    }
}
