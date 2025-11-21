// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OpenGL.GL3
import OSLog

struct MPVVideoView: NSViewRepresentable {
    let player: MPVPlayer
    
    func makeNSView(context: Context) -> MPVOpenGLHostView {
        guard
            let format = MPVOpenGLHostView.buildPixelFormat(),
            let view = MPVOpenGLHostView(frame: .zero, pixelFormat: format)
        else {
            fatalError("Failed to create MPVOpenGLHostView")
        }
        view.player = player
        return view
    }
    
    func updateNSView(_ nsView: MPVOpenGLHostView, context: Context) {
        // Updates handled via notifications
    }
}

@MainActor
final class MPVOpenGLHostView: NSOpenGLView {
    weak var player: MPVPlayer? {
        didSet {
            if oldValue !== player {
                needsMPVInit = true
            }
        }
    }
    
    private var needsMPVInit = true
    private var renderFBO: GLuint = 0
    private var renderTexture: GLuint = 0
    private var renderSize: CGSize = .zero
#if DEBUG
    private var debugSampleFramesRemaining = 8
#endif
    
    override init?(frame frameRect: NSRect, pixelFormat format: NSOpenGLPixelFormat?) {
        super.init(frame: frameRect, pixelFormat: format)
        guard openGLContext != nil else { return nil }
        sharedInit()
    }
    
    required init?(coder: NSCoder) {
        guard let format = MPVOpenGLHostView.buildPixelFormat() else {
            return nil
        }
        super.init(frame: .zero, pixelFormat: format)
        sharedInit()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        destroyRenderTargets()
    }
    
    private func sharedInit() {
        wantsBestResolutionOpenGLSurface = true
        NotificationCenter.default.addObserver(self, selector: #selector(handleRenderUpdate), name: .mpvRenderUpdate, object: nil)
    }
    
    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        glDisable(GLenum(GL_DITHER))
        glClearColor(0, 0, 0, 1)
        needsMPVInit = true
    }
    
    override func reshape() {
        super.reshape()
        openGLContext?.update()
        needsDisplay = true
    }
    
    @objc private func handleRenderUpdate() {
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        guard let player else { return }
        
        if needsMPVInit {
            let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
                guard let name else { return nil }
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            }
            player.initRenderContext(getProcAddress: getProcAddress)
            needsMPVInit = false
        }
        
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelSize = CGSize(width: max(1, round(bounds.width * scale)), height: max(1, round(bounds.height * scale)))
        
        guard ensureRenderTargets(for: pixelSize) else {
            glClearColor(0, 0, 0, 1)
            glClear(GLenum(GL_COLOR_BUFFER_BIT))
            context.flushBuffer()
            return
        }
        
        let pxWidth = GLsizei(pixelSize.width)
        let pxHeight = GLsizei(pixelSize.height)
        
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), renderFBO)
        glViewport(0, 0, pxWidth, pxHeight)
        checkGLError(context: "glViewport")
        #if DEBUG
        glClearColor(1, 0, 1, 1)
        #else
        glClearColor(0, 0, 0, 1)
        #endif
        glClear(GLenum(GL_COLOR_BUFFER_BIT))
        checkGLError(context: "glClear")
        
        Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVLayer").debug("Render: fbo=\(self.renderFBO) size=\(pixelSize.width)x\(pixelSize.height)")
        player.render(size: pixelSize, fbo: Int32(self.renderFBO))
        checkGLError(context: "player.render")
        
#if DEBUG
        if debugSampleFramesRemaining > 0 {
            var pixel: [UInt8] = [0, 0, 0, 0]
            glReadPixels(0, 0, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixel)
            checkGLError(context: "glReadPixels")
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVLayer").debug("Sampled pixel RGBA=\(pixel)")
            debugSampleFramesRemaining -= 1
        }
#endif
        
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glViewport(0, 0, pxWidth, pxHeight)
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), renderFBO)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
        glBlitFramebuffer(0, 0, GLint(pxWidth), GLint(pxHeight), 0, 0, GLint(pxWidth), GLint(pxHeight), GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))
        checkGLError(context: "glBlitFramebuffer")
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), 0)
        
        context.flushBuffer()
    }

    private func ensureRenderTargets(for pixelSize: CGSize) -> Bool {
        if renderFBO != 0 && renderSize == pixelSize {
            return true
        }
        destroyRenderTargets()
        renderSize = pixelSize
        let width = GLsizei(pixelSize.width)
        let height = GLsizei(pixelSize.height)
        
        glGenTextures(1, &renderTexture)
        glBindTexture(GLenum(GL_TEXTURE_2D), renderTexture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, width, height, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        
        glGenFramebuffers(1, &renderFBO)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), renderFBO)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), renderTexture, 0)
        
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if status != GLenum(GL_FRAMEBUFFER_COMPLETE) {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVLayer").error("Render FBO incomplete: \(status)")
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
            destroyRenderTargets()
            return false
        }
        
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        return true
    }
    
    private func destroyRenderTargets() {
        if renderFBO != 0 {
            var fbo = renderFBO
            glDeleteFramebuffers(1, &fbo)
            renderFBO = 0
        }
        if renderTexture != 0 {
            var tex = renderTexture
            glDeleteTextures(1, &tex)
            renderTexture = 0
        }
        renderSize = .zero
    }

    private func checkGLError(context: String) {
        let error = glGetError()
        if error != GLenum(GL_NO_ERROR) {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "MPVLayer").error("OpenGL error (\(context)): \(error)")
        }
    }
    
    static func buildPixelFormat() -> NSOpenGLPixelFormat? {
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADepthSize), 24,
            UInt32(NSOpenGLPFAStencilSize), 8,
            0
        ]
        return NSOpenGLPixelFormat(attributes: attrs)
    }
}

extension MPVOpenGLHostView {
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            player?.togglePause()
        } else {
            super.keyDown(with: event)
        }
    }
}
