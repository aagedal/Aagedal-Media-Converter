// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import QuartzCore
import OpenGL.GL3
import OSLog

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
    
    override func layout() {
        super.layout()
        if let layer = self.layer {
            layer.frame = self.bounds
        }
    }
    
    private func setupLayer() {
        let layer = MPVLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.isAsynchronous = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
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
        checkGLError(context: "glGetIntegerv(GL_FRAMEBUFFER_BINDING)")
        
        // Check framebuffer status
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if status != GLenum(GL_FRAMEBUFFER_COMPLETE) {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVLayer").error("Framebuffer incomplete (fbo=\(fbo)): \(status)")
            return
        }

        // Render
        let bounds = self.bounds
        let scale = self.contentsScale
        let pixelSize = CGSize(width: round(bounds.width * scale), height: round(bounds.height * scale))
        
        if pixelSize.width > 0 && pixelSize.height > 0 {
            // Skip rendering to FBO 0 as it causes GL_INVALID_FRAMEBUFFER_OPERATION (1286) in this context
            if fbo == 0 {
                // Just clear to BLACK
                glClearColor(0, 0, 0, 1)
                glClear(GLenum(GL_COLOR_BUFFER_BIT))
                return
            }

            // Explicitly set viewport
            glViewport(0, 0, GLsizei(pixelSize.width), GLsizei(pixelSize.height))
            checkGLError(context: "glViewport")
            
            // Clear to BLACK
            glClearColor(0, 0, 0, 1)
            glClear(GLenum(GL_COLOR_BUFFER_BIT))
            
            // Log render details occasionally
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVLayer").debug("Render: fbo=\(fbo) size=\(pixelSize.width)x\(pixelSize.height)")
            
            player.render(size: pixelSize, fbo: Int32(fbo))
            checkGLError(context: "player.render")
        } else {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVView").warning("Skipping render with invalid size: \(pixelSize.width)x\(pixelSize.height)")
        }
        
        glFlush()
        // CAOpenGLLayer documentation says: "You should not call super's implementation of this method."
        // super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }
    
    private func checkGLError(context: String) {
        let error = glGetError()
        if error != GLenum(GL_NO_ERROR) {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVLayer").error("OpenGL error (\(context)): \(error)")
        }
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
