// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Carbon.HIToolbox

struct VideoFileListView: View {
    @Binding var droppedFiles: [VideoItem]
    @Binding var currentProgress: Double
    var onFileImport: () -> Void
    var onDoubleClick: () -> Void
    var onDelete: (IndexSet) -> Void
    var onReset: (Int) -> Void
    var preset: ExportPreset
    
    @State private var isTargeted = false
    /// Selected row indices for built-in multi-selection
    @State private var selection = Set<Int>()
    @State private var focusedCommentID: UUID?

    var body: some View {
        ZStack {
            if droppedFiles.isEmpty {
                // Empty state with drag and drop instructions
                VStack {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                        .padding()
                    Text("Drag and drop video files here")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("or double-click to import files")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.windowBackgroundColor))
                .onTapGesture(count: 2) {
                    onDoubleClick()
                }
            } else {
                // File list
                // Enable multi-selection of rows by index
                List(selection: $selection) {
                    ForEach(Array(droppedFiles.indices), id: \.self) { index in
                        cardRow(for: index)
                    }
                    .onDelete(perform: onDelete)
                    .onMove { indices, newOffset in
                        droppedFiles.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .listStyle(PlainListStyle())
                .scrollContentBackground(.hidden) // matches new card background
                .background(Color.clear)
            }
            
            // Drag and drop overlay
            if isTargeted {
                Color.blue.opacity(0.1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [10]))
                            .foregroundColor(.blue)
                    )
            }
        }
        // Support file drops on entire view (empty or populated)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            return handleDrop(providers: providers)
        }
        .overlay(alignment: .topLeading) {
            ZStack {
                KeyEventHandlingView(
                    onTabForward: { handleTabPress(forward: true) },
                    onTabBackward: { handleTabPress(forward: false) }
                )

                Button(action: deleteSelectedItems) {
                    EmptyView()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .frame(width: 0, height: 0)
                .opacity(0)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        print(" handleDrop called with \(providers.count) providers")
        let supportedExtensions = AppConstants.supportedVideoExtensions
        var handled = false
        
        for provider in providers {
            print(" Processing provider: \(provider)")
            // Use the proper API to load file URLs
            if provider.canLoadObject(ofClass: URL.self) {
                print(" Provider can load URL")
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let error = error {
                        print(" Error loading URL: \(error)")
                        return
                    }
                    if let url = url {
                        print(" Loaded URL: \(url)")
                        
                        // For drag and drop, the URL already has temporary access
                        // We need to start accessing the security-scoped resource immediately
                        let hasAccess = url.startAccessingSecurityScopedResource()
                        print(" Security-scoped access granted: \(hasAccess)")
                        
                        Task { @MainActor in
                            await self.processFileURL(url, supportedExtensions: supportedExtensions, hasSecurityAccess: hasAccess)
                        }
                    } else {
                        print(" Provider cannot load URL")
                    }
                }
                handled = true
            } else {
                print(" Provider cannot load URL")
            }
        }
        
        print(" handleDrop returning: \(handled)")
        return handled
    }
    
    @MainActor
    private func processFileURL(_ url: URL, supportedExtensions: Set<String>, hasSecurityAccess: Bool = false) async {
        print(" Processing file URL: \(url)")
        
        // Get the file extension and check if it's supported
        let fileExtension = url.pathExtension.lowercased()
        print(" File extension: '\(fileExtension)'")
        print(" Supported extensions: \(supportedExtensions)")
        
        guard !fileExtension.isEmpty,
              supportedExtensions.contains(fileExtension) else {
            print(" File extension '\(fileExtension)' not supported")
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
                print(" Released security-scoped resource (unsupported file)")
            }
            return
        }
        
        print(" File extension is supported")
        
        // Handle security-scoped access based on the source
        var needsBookmarkAccess = false
        if !hasSecurityAccess {
            // Attempt to use an existing bookmark for persistent access
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
                needsBookmarkAccess = true
                print(" Successfully accessed security-scoped resource via bookmark")
            } else {
                // No bookmark found – rely on direct entitlements (e.g. Downloads/Movie directory access)
                if FileManager.default.isReadableFile(atPath: url.path) {
                    print(" Proceeding with direct file access (no bookmark needed)")
                } else {
                    print(" No bookmark and file not readable – access denied")
                    return
                }
            }
        } else {
            print(" Using existing security-scoped resource access")
        }
        
        defer {
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
                print(" Released security-scoped resource (drag and drop)")
            } else if needsBookmarkAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
                print(" Released security-scoped resource (bookmark)")
            }
        }
        
        // Save the bookmark for future access
        let bookmarkSaved = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        print(" Bookmark saved: \(bookmarkSaved)")
        
        // Get the output folder from UserDefaults or use default
        let outputFolder = UserDefaults.standard.string(forKey: "outputFolder") 
            ?? AppConstants.defaultOutputDirectory.path
            
        if let videoItem = await VideoFileUtils.createVideoItem(
            from: url,
            outputFolder: outputFolder,
            preset: preset
        ) {
            print(" Created video item: \(videoItem.name)")
            // Check for duplicates before adding
            if !self.droppedFiles.contains(where: { $0.url == videoItem.url }) {
                self.droppedFiles.append(videoItem)
                print(" Added video item to list. Total items: \(self.droppedFiles.count)")
            } else {
                print(" Video item already exists in list")
            }
        } else {
            print(" Failed to create video item")
        }
    }
    
    private func progressText(for item: VideoItem) -> String {
        switch item.status {
        case .waiting:
            return "Waiting"
        case .converting:
            if let eta = item.eta {
                return "Converting... ETA: \(eta)"
            } else {
                return "Converting..."
            }
        case .done:
            return "Done"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }

    private func handleTabPress(forward: Bool) {
        focusComment(forward: forward, currentFocused: focusedCommentID)
    }

    private func focusComment(forward: Bool, currentFocused: UUID?) {
        guard !droppedFiles.isEmpty else { return }

        let sortedSelection = selection.sorted()

        if let currentIndex = sortedSelection.first {
            let currentID = droppedFiles[currentIndex].id
            if currentFocused == currentID,
               let nextIndex = nextIndex(from: currentIndex, forward: forward) {
                selection = [nextIndex]
                focusedCommentID = droppedFiles[nextIndex].id
            } else {
                focusedCommentID = currentID
            }
            return
        }

        if let currentFocused,
           let currentIndex = droppedFiles.firstIndex(where: { $0.id == currentFocused }) {
            if let nextIndex = nextIndex(from: currentIndex, forward: forward) {
                selection = [nextIndex]
                focusedCommentID = droppedFiles[nextIndex].id
            }
            return
        }

        let startIndex = forward ? 0 : max(droppedFiles.count - 1, 0)
        selection = [startIndex]
        focusedCommentID = droppedFiles[startIndex].id
    }

    private func nextIndex(from currentIndex: Int, forward: Bool) -> Int? {
        guard !droppedFiles.isEmpty else { return nil }
        let delta = forward ? 1 : -1
        let nextIndex = (currentIndex + delta + droppedFiles.count) % droppedFiles.count
        return nextIndex
    }

    private func deleteSelectedItems() {
        let indices = IndexSet(selection)
        guard !indices.isEmpty else { return }
        onDelete(indices)
        selection.removeAll()
        focusedCommentID = nil
    }
    
    // MARK: - Row Builder
    @ViewBuilder
    private func cardRow(for index: Int) -> some View {
        // Get a binding to the file in the array
        let file = $droppedFiles[index]
        VideoFileRowView(
            file: file,
            focusedCommentID: $focusedCommentID,
            preset: preset,
            onCancel: {
                Task { await ConversionManager.shared.cancelItem(with: file.wrappedValue.id) }
            },
            onDelete: {
                onDelete(IndexSet(integer: index))
            },
            onReset: {
                onReset(index)
            },
            isSelected: selection.contains(index),
            onCommentFocusChange: { id, isFocused in
                guard droppedFiles[index].id == id else { return }
                if isFocused {
                    selection = [index]
                    focusedCommentID = id
                } else if focusedCommentID == id {
                    focusedCommentID = nil
                }
            }
        )
        .padding([.vertical], 4)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }
}

struct VideoFileListView_Previews: PreviewProvider {
    static var previews: some View {
        VideoFileListView(
            droppedFiles: .constant([
                VideoItem(
                    url: URL(fileURLWithPath: "/tmp/SampleVideo.mp4"),
                    name: "SampleVideo.mp4",
                    size: 1048576,
                    duration: "00:02:30",
                    thumbnailData: nil,
                    status: .waiting,
                    progress: 0.0,
                    eta: nil
                ),
                VideoItem(
                    url: URL(fileURLWithPath: "/tmp/SampleVideo2.mp4"),
                    name: "SampleVideo2.mp4",
                    size: 1048576,
                    duration: "00:01:30",
                    thumbnailData: nil,
                    status: .done,
                    progress: 0.0,
                    eta: nil
                ),
                VideoItem(
                    url: URL(fileURLWithPath: "/tmp/SampleVideo3.mp4"),
                    name: "SampleVideo.mp4",
                    size: 1048576,
                    duration: "00:05:30",
                    thumbnailData: nil,
                    status: .cancelled,
                    progress: 0.0,
                    eta: nil
                )
            ]),
            currentProgress: .constant(0.5),
            onFileImport: {},
            onDoubleClick: {},
            onDelete: { _ in },
            onReset: { _ in },
            preset: .videoLoop
        )
    }
}

private func generateThumbnailWithFFmpeg(from url: URL) -> NSImage? {
    let tempDir = FileManager.default.temporaryDirectory
    let outputURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
    
    let process = Process()
    process.executableURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)
    
    // Get video duration
    let durationProcess = Process()
    durationProcess.executableURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil)
    durationProcess.arguments = [
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        url.path
    ]
    
    let durationPipe = Pipe()
    durationProcess.standardOutput = durationPipe
    
    do {
        try durationProcess.run()
        durationProcess.waitUntilExit()
        
        let durationData = durationPipe.fileHandleForReading.readDataToEndOfFile()
        if let durationString = String(data: durationData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let duration = Double(durationString) {
            
            // Seek to 10% of the video to avoid intros/black screens
            let seekTime = min(10, duration * 0.1)
            
            process.arguments = [
                "-ss", String(seekTime),
                "-i", url.path,
                "-vframes", "1",
                "-q:v", "2", // Quality (2-31, lower is better)
                "-vf", "scale=320:-1", // Scale width to 320px, maintain aspect ratio
                "-y", // Overwrite output file if it exists
                outputURL.path
            ]
            
            try process.run()
            process.waitUntilExit()
            
            if let image = NSImage(contentsOf: outputURL) {
                try? FileManager.default.removeItem(at: outputURL)
                return image
            }
        }
    } catch {
        print("Error generating thumbnail with FFmpeg: \(error)")
    }
    
    return nil
}

private struct KeyEventHandlingView: NSViewRepresentable {
    var onTabForward: () -> Void
    var onTabBackward: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onForward: onTabForward, onBackward: onTabBackward)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onForward = onTabForward
        context.coordinator.onBackward = onTabBackward
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator {
        var onForward: () -> Void
        var onBackward: () -> Void
        private var monitor: Any?

        init(onForward: @escaping () -> Void, onBackward: @escaping () -> Void) {
            self.onForward = onForward
            self.onBackward = onBackward
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.keyCode == kVK_Tab else { return event }

                let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
                if !event.modifierFlags.intersection(disallowedModifiers).isEmpty {
                    return event
                }

                // Always handle Tab for comment field cycling
                if event.modifierFlags.contains(.shift) {
                    self.onBackward()
                } else {
                    self.onForward()
                }
                return nil
            }
        }

        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
