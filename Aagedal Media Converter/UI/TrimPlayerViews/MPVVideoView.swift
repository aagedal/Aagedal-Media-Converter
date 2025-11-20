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
        layer.isAsynchronous = true
        self.layer = layer
        self.glLayer = layer
    }
    
    private func setupPlayer(_ player: MPVPlayer) {
        guard let layer = glLayer as? MPVLayer else { return }
        layer.player = player
    }
}

class MPVLayer: CAOpenGLLayer, @unchecked Sendable {
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
        self.setNeedsDisplay()
    }
    
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attributes: [CGLPixelFormatAttribute] = [
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
    
    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let player = player else { return }
        
        CGLSetCurrentContext(ctx)
        
        if !isInitialized {
            // Initialize MPV render context
            let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
                guard let name = name else { return nil }
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT = -2
            }
            
            player.initRenderContext(getProcAddress: getProcAddress)
            isInitialized = true
        }
        
        // Get FBO
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
        
        // Render
        let bounds = self.bounds
        let scale = self.contentsScale
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        player.render(size: pixelSize, fbo: Int32(fbo))
        
        glFlush()
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }
}

extension MPVOpenGLView {
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            player?.togglePause()
        } else {
            super.keyDown(with: event)
        }
    }
}
