// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Always-on file-drop backstop placed at the bottom of the queue ZStack.
///
/// Replaces SwiftUI's `.onDrop` for the queue area: the SwiftUI version stopped
/// firing reliably once encoding-group cells were added (the NSTableView under
/// it claims drag events when populated, and the SwiftUI hit-test fell through
/// in the empty state). An explicit AppKit drop view gives us a guaranteed hit
/// shape and a hover-state callback the SwiftUI overlay can react to.
///
/// When the queue has rows the NSTableView sits on top and intercepts drags;
/// this backstop only sees drops in the empty state. The "drag is over the
/// queue (not over a group)" highlight in the populated state comes from
/// `VideoQueueTableView`'s own callback.
struct FileDropBackstop: NSViewRepresentable {
    @Binding var isHovering: Bool
    var onDropURLs: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = DropView()
        view.coordinator = context.coordinator
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator {
        var parent: FileDropBackstop
        init(_ parent: FileDropBackstop) { self.parent = parent }

        @MainActor
        func setHovering(_ value: Bool) {
            // Avoid SwiftUI churn from repeated equal updates.
            if parent.isHovering != value {
                parent.isHovering = value
            }
        }
    }

    final class DropView: NSView {
        weak var coordinator: Coordinator?

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            // Refuse drags with nothing the queue can import (e.g. only unsupported
            // file types) so the user gets the standard "can't drop" feedback
            // instead of a highlight followed by nothing happening.
            guard !supportedFileURLs(sender).isEmpty else { return [] }
            DispatchQueue.main.async { [weak self] in self?.coordinator?.setHovering(true) }
            return .copy
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            supportedFileURLs(sender).isEmpty ? [] : .copy
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            DispatchQueue.main.async { [weak self] in self?.coordinator?.setHovering(false) }
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            DispatchQueue.main.async { [weak self] in self?.coordinator?.setHovering(false) }
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            !supportedFileURLs(sender).isEmpty
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            DispatchQueue.main.async { [weak self] in self?.coordinator?.setHovering(false) }
            let urls = supportedFileURLs(sender)
            guard !urls.isEmpty else { return false }
            coordinator?.parent.onDropURLs(urls)
            return true
        }

        /// Folders and supported files on the drag pasteboard, in pasteboard
        /// order. Folders are searched on import; a folder without media
        /// simply adds nothing.
        private func supportedFileURLs(_ sender: any NSDraggingInfo) -> [URL] {
            guard sender.draggingPasteboard.types?.contains(.fileURL) == true else { return [] }
            let urls = (sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]) ?? []
            let supported = AppConstants.supportedVideoExtensions
            return urls.filter {
                supported.contains($0.pathExtension.lowercased()) || FolderImportScanner.isImportableFolder($0)
            }
        }
    }
}
