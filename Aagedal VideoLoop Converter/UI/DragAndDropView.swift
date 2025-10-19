// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit
import AVFoundation

struct DragAndDropView: NSViewRepresentable {
    @Binding var droppedFiles: [VideoItem]
    
    // Using centralized VideoFileUtils for video file handling
    
    class Coordinator: NSObject, NSDraggingDestination {
        var parent: DragAndDropView
        
        init(parent: DragAndDropView) {
            self.parent = parent
        }
        
        func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
                return false
            }
            
            Task {
                for url in urls {
                    if let videoItem = await VideoFileUtils.createVideoItem(from: url) {
                        await MainActor.run {
                            if !parent.droppedFiles.contains(where: { $0.url == url }) {
                                parent.droppedFiles.append(videoItem)
                            }
                        }
                    } else {
                        print("Skipping unsupported file: \(url.lastPathComponent)")
                    }
                }
            }
            
            return true
        }

        func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            return .copy
        }

        func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            return true
        }

        func concludeDragOperation(_ sender: NSDraggingInfo?) {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class DraggingView: NSView {
        weak var coordinator: Coordinator?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            coordinator?.draggingEntered(sender) ?? []
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            coordinator?.prepareForDragOperation(sender) ?? false
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            coordinator?.performDragOperation(sender) ?? false
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            coordinator?.concludeDragOperation(sender)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = DraggingView()
        view.coordinator = context.coordinator
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
