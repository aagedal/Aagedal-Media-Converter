// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AVFoundation
import AppKit

struct VideoFileRowView: View {
    @Binding var file: VideoItem
    @Binding var focusedCommentID: UUID?
    let preset: ExportPreset
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onReset: () -> Void
    /// Indicates if this row is selected in the list
    var isSelected: Bool = false
    var onCommentFocusChange: (UUID, Bool) -> Void = { _, _ in }

    // Show yellow warning icon when VideoLoop preset is used on clips longer than 15 s
    private var showDurationWarning: Bool {
        (preset == .videoLoop || preset == .videoLoopWithAudio) && file.durationSeconds > 15
    }
    @FocusState private var isCommentFieldFocused: Bool
    @State private var isThumbnailHovered = false
    @State private var showPreview = false
    @State private var showMetadata = false
    @State private var cachedThumbnail: NSImage?
    @State private var localComment: String = ""
    @State private var isBeingDeleted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 0.8)
                )
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
            
            VStack(spacing: 0) {
                HStack {
                    // Thumbnail
                    ZStack {
                        CheckerboardBackground()
                            .frame(width: 200, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.black.opacity(0.2), lineWidth: 1)
                            .frame(width: 200, height: 150)

                        if let cachedImage = cachedThumbnail {
                            Image(nsImage: cachedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 200, height: 150)
                                .cornerRadius(4)
                        } else {
                            VStack {
                                Image(systemName: "film")
                                    .font(.largeTitle)
                                Text("Generating thumbnail...")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        // Trim indicator badge
                        if file.trimStart != nil || file.trimEnd != nil {
                            HStack(spacing: 4) {
                                Image(systemName: "scissors")
                                    .font(.caption2)
                                Text(formattedTime(file.trimmedDuration))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                            .padding(8)
                        }
                    }
                    .overlay {
                        if isThumbnailHovered {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.black.opacity(0.35))
                                    .frame(width: 200, height: 150)
                                    .allowsHitTesting(false)
                                
                                VStack {
                                    Spacer()
                                    HStack(spacing: 12) {
                                        Button {
                                            showPreview = true
                                        } label: {
                                            Label("Preview", systemImage: "timeline.selection")
                                                .labelStyle(.iconOnly)
                                                .font(.system(size: 28, weight: .medium))
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(.white)
                                        .help("Open preview and trim editor")
                                        
                                        Spacer()

                                        //if file.metadata != nil {
                                            Button {
                                                showMetadata = true
                                            } label: {
                                                Label("Metadata", systemImage: "info.circle")
                                                    .labelStyle(.iconOnly)
                                                    .font(.system(size: 24, weight: .medium))
                                                    .disabled(file.metadata == nil)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundColor(.white)
                                            .help("View technical metadata")
                                        //}
                                    }.padding(10)
                                }

                            }
                            .transition(.opacity)
                        }
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isThumbnailHovered = hovering
                        }
                    }
                    .onTapGesture {
                        showPreview = true
                    }
                    .help("Click to preview and trim video")
                    
                    VStack(alignment: .leading, spacing: 4) {
                        // Input and output file names
                        HStack {
                            Text(file.name)
                                .font(.headline)
                            // Duration warning icon
                            Text("→")
                            HStack(spacing: 4) {
                                Text(displayOutputFilename())
                                    .font(.headline)
                                    .foregroundColor((file.status == .waiting && file.outputFileExists) ? .orange : .primary)
                                
                                if let outputURL = file.outputURL {
                                    HStack(spacing: 6) {
                                        if file.status == .waiting && file.outputFileExists {
                                            Button(action: {
                                                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                            }) {
                                                Image(systemName: "magnifyingglass.circle.fill")
                                                    .foregroundColor(.orange)
                                                    .help("Output file already exists and will be overwritten during conversion. Click to show in Finder.")
                                            }
                                            .buttonStyle(BorderlessButtonStyle())
                                            dragIcon(
                                                for: outputURL,
                                                color: Color.orange,
                                                helpText: "Output file already exists and will be overwritten during conversion. Drag to share or archive before converting."
                                            )
                                        }

                                        if file.status == .done {
                                            Button(action: {
                                                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                            }) {
                                                Image(systemName: "magnifyingglass.circle.fill")
                                                    .foregroundColor(.blue)
                                                    .help("Show in Finder")
                                            }
                                            .buttonStyle(BorderlessButtonStyle())
                                            dragIcon(
                                                for: outputURL,
                                                color: Color.blue,
                                                helpText: "Drag this icon to share the exported file with other apps."
                                            )
                                        }
                                    }
                                }
                            }
                            Spacer()
                        }
                        
                        // Progress and status
                        if file.status == .converting {
                            ProgressView(value: file.progress)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                        
                        // Metadata
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Duration: \(file.duration)")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            if showDurationWarning {
                                Image(systemName: "exclamationmark.triangle.fill").font(.subheadline)
                                    .foregroundColor(.yellow)
                                    .help("Duration exceeds 15 seconds. VideoLoops are best suited for shorter videos.")
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Text("Input Size: \(file.formattedSize)")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                
                            if file.status == .waiting && file.outputFileExists {
                                Text("•")
                                    .foregroundColor(.gray)
                                Text("Existing file will be overwritten")
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                            }
                            
                            Spacer()
                            
                            // Status
                            Text(progressText)
                                .font(.subheadline)
                                .foregroundColor(statusColor)
                            
                            // Action buttons
                            if file.status == .converting {
                                Button(action: onCancel) {
                                    Image(systemName: "xmark.circle")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .help("Cancel conversion")
                            } else {
                                Button(action: {
                                    // Set deletion flag and clear focus BEFORE deleting
                                    isBeingDeleted = true
                                    if isCommentFieldFocused || focusedCommentID == file.id {
                                        isCommentFieldFocused = false
                                        focusedCommentID = nil
                                    }
                                    onDelete()
                                }) {
                                    Image(systemName: "clear")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .help("Remove from list")
                                
                                if file.status != .waiting {
                                    Button(action: onReset) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .foregroundStyle(file.status == .converting || file.status == .waiting ? .gray : .blue)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                    .help("Reset conversion")
                                    .disabled(file.status == .converting || file.status == .waiting)
                                }
                            }
                        }
                        commentSection
                    }
                    .padding()
                }
            }
        }
        .padding(.horizontal, 4)
        .sheet(isPresented: $showPreview) {
            PreviewPlayerView(item: $file)
        }
        .sheet(isPresented: $showMetadata) {
            VideoMetadataView(item: $file)
        }
        .task(id: file.thumbnailData) {
            // Decode thumbnail asynchronously off main thread
            guard let data = file.thumbnailData else {
                cachedThumbnail = nil
                return
            }
            
            // Simple async decode - let SwiftUI handle aspect ratio
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                NSImage(data: data)
            }.value
            
            cachedThumbnail = image
        }
        .onAppear {
            // Initialize local comment from file
            localComment = file.comment
        }
        .onChange(of: file.comment) { _, newComment in
            // Sync local comment when file comment changes externally
            if !isCommentFieldFocused {
                localComment = newComment
            }
        }
        .onChange(of: localComment) { _, newValue in
            // Sync local comment back to file when changed (only if not being deleted)
            if !isBeingDeleted && isCommentFieldFocused && file.status == .waiting {
                file.comment = newValue
            }
        }
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack{
                waveformToggle.padding(.trailing, 40)
                includeDateTagToggle
            }.frame(width: 350, alignment: .trailing)
                .padding(.bottom, 6)
            commentEditor
        }
        .padding(.top, 12)
        
    }

    private var commentEditor: some View {
        let commentIsEditable = file.status == .waiting
        let commentBinding = Binding(
            get: { 
                // Return local copy - safe even if file is deleted
                return localComment
            },
            set: { (newValue: String) in
                // Update local copy immediately - don't access file here
                localComment = newValue
                // Sync will happen via onChange(of: localComment) below
            }
        )
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .frame(maxWidth: .infinity)
            TextField("", text: commentBinding, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .lineLimit(1)
                .focused($isCommentFieldFocused)
                .disabled(!commentIsEditable)
                .opacity(commentIsEditable ? 1 : 0.6)
                .frame(height: 20)
                .padding(.horizontal, 5)
                .padding(.top, 1)
                .onSubmit {
                    isCommentFieldFocused = false
                    focusedCommentID = nil
                }
                .onChange(of: file.status) { (_: ConversionManager.ConversionStatus, newStatus: ConversionManager.ConversionStatus) in
                    // Clear focus if file is being deleted or processed
                    if newStatus != .waiting && isCommentFieldFocused {
                        isCommentFieldFocused = false
                        if focusedCommentID == file.id {
                            focusedCommentID = nil
                        }
                    }
                }
            .onChange(of: focusedCommentID) { oldValue, newValue in
                print("📍 focusedCommentID changed: \(oldValue?.uuidString.prefix(8) ?? "nil") → \(newValue?.uuidString.prefix(8) ?? "nil"), myID: \(file.id.uuidString.prefix(8))")
                guard commentIsEditable else {
                    if isCommentFieldFocused {
                        isCommentFieldFocused = false
                    }
                    return
                }
                isCommentFieldFocused = (newValue == file.id)
            }
            .onChange(of: isCommentFieldFocused) { _, isFocused in
                print("✏️ isCommentFieldFocused changed to \(isFocused) for file \(file.id.uuidString.prefix(8))")
                guard commentIsEditable else {
                    if isFocused {
                        isCommentFieldFocused = false
                    }
                    if focusedCommentID == file.id {
                        focusedCommentID = nil
                    }
                    return
                }
                if isFocused {
                    focusedCommentID = file.id
                    onCommentFocusChange(file.id, true)
                } else if focusedCommentID == file.id {
                    focusedCommentID = nil
                    onCommentFocusChange(file.id, false)
                }
            }
            if file.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add a comment (single line)...")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .allowsHitTesting(false)
                    .padding(.horizontal, 5)
                    .padding(.top, 4)
            }
        }
        .frame(height: 20)
        .onChange(of: isSelected) { _, selected in
            print("📌 Row selection changed to \(selected) for file \(file.id.uuidString.prefix(8))")
            guard commentIsEditable else {
                if isCommentFieldFocused {
                    isCommentFieldFocused = false
                }
                if focusedCommentID == file.id {
                    focusedCommentID = nil
                }
                return
            }
            if selected && !isCommentFieldFocused {
                // When row is selected, focus the comment field
                print("  ➡️ Auto-focusing comment field because row was selected")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedCommentID = file.id
                    isCommentFieldFocused = true
                }
            }
        }
   }

    private var waveformToggle: some View {
        let waveformBinding = Binding(
            get: { file.waveformVideoEnabled },
            set: { file.waveformVideoEnabled = $0 }
        )
        return Toggle("Waveform video", isOn: waveformBinding)
            .controlSize(.mini)
            .font(.subheadline)
            .toggleStyle(SwitchToggleStyle())
            .disabled(file.hasVideoStream)
            .opacity(file.hasVideoStream ? 0.4 : 1.0)
            .help(file.hasVideoStream ? "Waveform video is only available for audio-only sources." : "Generate a waveform video when exporting this item.")
    }

    private var includeDateTagToggle: some View {
        let includeDateBinding = Binding(
            get: { file.includeDateTag },
            set: { file.includeDateTag = $0 }
        )
        return Toggle("Include date tag", isOn: includeDateBinding)
            .controlSize(.mini)
            .font(.subheadline)
            .toggleStyle(SwitchToggleStyle())
            .help("Include 'Date generated: YYYYMMDD' in the video metadata comment field.")
    }
    
    private var progressText: String {
        switch file.status {
        case .waiting:
            return "Waiting"
        case .converting:
            if let eta = file.eta {
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
    
    private var statusColor: Color {
        switch file.status {
        case .done: return .green
        case .converting: return .blue
        case .cancelled: return .orange
        case .failed: return .red
        default: return .gray
        }
    }
    
    private func displayOutputFilename() -> String {
        if let outputURL = file.outputURL {
            return outputURL.lastPathComponent
        }
        return generateOutputFilename(from: file.name)
    }

    private func generateOutputFilename(from input: String) -> String {
        let filename = (input as NSString).deletingPathExtension
        let sanitized = FileNameProcessor.processFileName(filename)
        return "\(sanitized)\(preset.fileSuffix).\(preset.fileExtension)"
    }

    private func dragIcon(for outputURL: URL, color: Color, helpText: String) -> some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .foregroundColor(color)
            .help(helpText)
            .onDrag {
                let provider = NSItemProvider(object: outputURL as NSURL)
                provider.suggestedName = outputURL.lastPathComponent
                return provider
            }
    }
    
    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}

struct VideoFileRowView_Previews: PreviewProvider {
    struct Preview: View {
        @State private var item = VideoItem(
            url: URL(fileURLWithPath: "/path/to/video.mp4"),
            name: "Sample Video",
            size: 1024 * 1024 * 100, // 100MB
            duration: "01:23:45",
            thumbnailData: nil,
            status: .waiting,
            progress: 0.0,
            eta: nil,
            outputURL: nil,
            comment: "This is a sample comment"
        )
        @State private var focusedCommentID: UUID?
        
        var body: some View {
            VideoFileRowView(
                file: $item,
                focusedCommentID: $focusedCommentID,
                preset: .videoLoop,
                onCancel: {},
                onDelete: {},
                onReset: {}
            )
            .frame(width: 800, height: 150)
            .padding()
        }
    }
    
    static var previews: some View {
        Preview()
    }
}

struct VideoFileRowView_Previews2: PreviewProvider {
    struct Preview: View {
        @State private var item = VideoItem(
            url: URL(fileURLWithPath: "/path/to/video2.mp4"),
            name: "Sample Video 2",
            size: 1024 * 1024 * 100, // 100MB
            duration: "01:23:45",
            thumbnailData: nil,
            status: .converting,
            progress: 0.3,
            eta: "00:01:23",
            outputURL: nil,
            comment: "This is another sample comment"
        )
        @State private var focusedCommentID: UUID?
        
        var body: some View {
            VideoFileRowView(
                file: $item,
                focusedCommentID: $focusedCommentID,
                preset: .videoLoop,
                onCancel: {},
                onDelete: {},
                onReset: {}
            )
            .frame(width: 800, height: 150)
            .padding()
        }
    }
    
    static var previews: some View {
        Preview()
    }
}
