// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import QuartzCore
import OpenGL.GL3

struct MPVVideoView: NSViewRepresentable {
    let player: MPVPlayer
    
    func makeNSView(context: Context) -> MPVOpenGLView {
        let view = MPVOpenGLView()
        view.player = player
        return view
    }
    
    func updateNSView(_ nsView: MPVOpenGLView, context: Context) {
        // Updates handled by player state
    }
}

final class MPVOpenGLView: NSView {
    var player: MPVPlayer? {
        didSet {
            if let player = player {
                setupPlayer(player)
            }
        }
    }
    
    private var glLayer: CAOpenGLLayer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        setupLayer()
    }
    
    private func setupLayer() {
        let layer = MPVLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.asynchronous = true
        self.layer = layer
        self.glLayer = layer
    }
    
    private func setupPlayer(_ player: MPVPlayer) {
        guard let layer = glLayer as? MPVLayer else { return }
        layer.player = player
    }
}

class MPVLayer: CAOpenGLLayer {
    weak var player: MPVPlayer?
    private var isInitialized = false
    
    override init() {
        super.init()
        self.needsDisplayOnBoundsChange = true
        // Register for updates
        NotificationCenter.default.addObserver(self, selector: #selector(needsDraw), name: .mpvRenderUpdate, object: nil)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(self, selector: #selector(needsDraw), name: .mpvRenderUpdate, object: nil)
    }
    
    @objc private func needsDraw() {
        DispatchQueue.main.async {
            self.setNeedsDisplay()
        }
    }
    
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        var attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAColorSize, CGLPixelFormatAttribute(24),
            kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
            kCGLPFADepthSize, CGLPixelFormatAttribute(24),
            kCGLPFAStencilSize, CGLPixelFormatAttribute(8),
            kCGLPFANoRecovery,
            CGLPixelFormatAttribute(0)
        ]
        
        var pix: CGLPixelFormatObj?
        var num: GLint = 0
        CGLChoosePixelFormat(attributes, &pix, &num)
        return pix!
    }
    
    override func draw(in ctx: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: CVTimeStamp) {
        guard let player = player else { return }
        
        CGLSetCurrentContext(ctx)
        
        if !isInitialized {
            // Initialize MPV render context
            // We need to pass a function pointer for getProcAddress
            // Since this is a C callback, we can't capture 'ctx' easily if it changes, 
            // but CGLContextObj is effectively global for this thread during draw.
            // However, mpv expects a persistent function.
            // Standard OpenGL on macOS doesn't really need getProcAddress for core functions,
            // but mpv might need it.
            // For macOS CGL, we can usually pass a simple wrapper around dlsym/NSGLGetProcAddress if needed,
            // or just nil if mpv's default backend handles it (which it often does on macOS).
            // Let's try passing a simple resolver.
            
            let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
                guard let name = name else { return nil }
                // macOS symbols are usually available globally if linked, or we can look them up.
                // But actually, for CGL, we don't have a standard getProcAddress.
                // Usually passing NULL works for core profile on macOS as symbols are weak-linked.
                return nil 
            }
            
            player.initRenderContext(getProcAddress: getProcAddress)
            isInitialized = true
        }
        
        // Get FBO
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
        
        // Render
        player.render(size: self.bounds.size, fbo: Int32(fbo))
        
        glFlush()
        super.draw(in: ctx, pixelFormat: pixelFormat, forLayerTime: t, displayTime: ts)
    }
}
