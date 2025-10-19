// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AppKit
import SwiftUI

class DockProgressView: NSView {
    private var progress: Double = 0.0
    private var appIcon: NSImage?
    
    init(progress: Double) {
        self.progress = progress
        self.appIcon = NSApplication.shared.applicationIconImage
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateProgress(_ progress: Double) {
        self.progress = progress
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Fill background with clear
        NSColor.clear.set()
        dirtyRect.fill()
        
        // Draw app icon
        if let appIcon = appIcon {
            let iconSize = min(bounds.width, bounds.height) * 0.9
            let iconRect = NSRect(
                x: (bounds.width - iconSize) / 2,
                y: (bounds.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            
            // Draw app icon with rounded corners
            let cornerRadius: CGFloat = iconSize * 0.2
            let clipPath = NSBezierPath(
                roundedRect: iconRect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            )
            
            NSGraphicsContext.saveGraphicsState()
            clipPath.setClip()
            appIcon.draw(in: iconRect)
            NSGraphicsContext.restoreGraphicsState()
        }
        
        // Only show progress if it's between 0 and 1 (exclusive)
        guard progress > 0.0 && progress < 1.0 else { return }
        
        // Draw progress circle
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.45
        let lineWidth: CGFloat = 4.0
        
        // Background circle (semi-transparent black)
        let backgroundPath = NSBezierPath()
        backgroundPath.appendArc(withCenter: center,
                               radius: radius,
                               startAngle: 0,
                               endAngle: 360)
        NSColor(white: 0.0, alpha: 0.6).setFill()
        backgroundPath.fill()
        
        // Progress arc (white)
        let progressPath = NSBezierPath()
        let startAngle: CGFloat = 90.0 // Start from top
        let endAngle = startAngle - (360.0 * CGFloat(progress))
        
        progressPath.appendArc(withCenter: center,
                             radius: radius - lineWidth / 2,
                             startAngle: startAngle,
                             endAngle: endAngle,
                             clockwise: true)
        
        progressPath.lineWidth = lineWidth
        progressPath.lineCapStyle = .round
        NSColor.white.setStroke()
        progressPath.stroke()
        
        // Progress percentage in the center
        let progressText = "\(Int(progress * 100))%"
        let textAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: radius * 0.4, weight: .bold)
        ]
        
        let textSize = progressText.size(withAttributes: textAttributes)
        let textRect = NSRect(
            x: center.x - textSize.width / 2,
            y: center.y - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        
        // Add a shadow to the text for better visibility
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        shadow.shadowBlurRadius = 2
        shadow.set()
        
        progressText.draw(in: textRect, withAttributes: textAttributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// Helper to update the dock tile
@MainActor
class DockProgressUpdater {
    private var progressView: DockProgressView?
    private var progressTask: Task<Void, Never>?
    private var originalContentView: NSView?
    private var isShowingProgress = false
    
    init() {
        // Don't set up the dock tile until needed
    }
    
    private func setupDockTile() {
        guard !isShowingProgress else { return }
        
        // Store the original content view if we haven't already
        if originalContentView == nil {
            originalContentView = NSApp.dockTile.contentView
        }
        
        // Create and set up the progress view
        progressView = DockProgressView(progress: 0.0)
        
        let customView = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        customView.wantsLayer = true
        customView.layer?.backgroundColor = NSColor.clear.cgColor
        
        if let progressView = progressView {
            progressView.frame = customView.bounds
            customView.addSubview(progressView)
        }
        
        // Set the custom view as the content of the dock tile
        NSApp.dockTile.contentView = customView
        isShowingProgress = true
        
        // Force redraw
        NSApp.dockTile.display()
    }
    
    func updateProgress(_ progress: Double) {
        // Always set up the dock tile when updating progress
        if !isShowingProgress {
            setupDockTile()
        }
        
        let clampedProgress = min(max(progress, 0.0), 1.0)
        progressView?.updateProgress(clampedProgress)
        NSApp.dockTile.display()
        
        // If progress is 0 or 1, reset the dock tile after a short delay
        // but only if we're actually showing progress (not just initializing)
        if isShowingProgress && (clampedProgress == 0.0 || clampedProgress == 1.0) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                if !Task.isCancelled && (clampedProgress == 0.0 || clampedProgress == 1.0) {
                    reset()
                }
            }
        }
    }
    
    func reset() {
        guard isShowingProgress else { return }
        
        // Restore the original content view
        NSApp.dockTile.contentView = originalContentView
        originalContentView = nil
        progressView = nil
        isShowingProgress = false
        
        // Force redraw
        NSApp.dockTile.display()
    }
    
    deinit {
        progressTask?.cancel()
        // Schedule reset to run on the main thread
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.reset()
            }
        }
    }
}
