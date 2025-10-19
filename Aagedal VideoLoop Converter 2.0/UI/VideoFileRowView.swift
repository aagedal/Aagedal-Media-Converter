// Aagedal VideoLoop Converter 2.0
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
    let preset: ExportPreset
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onReset: () -> Void
    /// Indicates if this row is selected in the list
    var isSelected: Bool = false
    
    // Show yellow warning icon when VideoLoop preset is used on clips longer than 15 s
    private var showDurationWarning: Bool {
        (preset == .videoLoop || preset == .videoLoopWithAudio) && file.durationSeconds > 15
    }
    
    @State private var isEditingComment = false
    @State private var editedComment = ""
    
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
                        Rectangle()
                            .frame(width: 150, height: 150)
                            .cornerRadius(9)
                            .foregroundColor(.black)
                            .padding(2)
                        
                        if let data = file.thumbnailData, let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 150, height: 150)
                                .cornerRadius(4)
                        } else {
                            Image(systemName: "film")
                                .padding()
                                .font(.largeTitle)
                        }
                    }
                    .padding(.leading)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        // Input and output file names
                        HStack {
                            Text(file.name)
                                .font(.headline)
                            // Duration warning icon
                            Text("→")
                            HStack(spacing: 4) {
                                Text(generateOutputFilename(from: file.name))
                                    .font(.headline)
                                    .foregroundColor((file.status == .waiting && file.outputFileExists) ? .orange : .primary)
                                
                                if file.status == .waiting && file.outputFileExists, let outputURL = file.outputURL {
                                    Button(action: {
                                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                    }) {
                                        Image(systemName: "magnifyingglass.circle.fill")
                                            .foregroundColor(.orange)
                                            .help("Output file already exists. Click to show in Finder")
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                                
                                if file.status == .done, let outputURL = file.outputURL {
                                    Button(action: {
                                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                    }) {
                                        Image(systemName: "magnifyingglass.circle.fill")
                                            .foregroundColor(.blue)
                                            .help("Show in Finder")
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
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
                        HStack {
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
                            } else if file.status == .done || file.status == .failed {
                                Button(action: onDelete) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .help("Remove from list")
                                
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
                    .padding()
                }
                
                // Comment section
                HStack {
                    if isEditingComment {
                        HStack {
                            TextField("Add a comment...", text: $editedComment, onCommit: {
                                file.comment = editedComment
                                isEditingComment = false
                            })
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(maxWidth: .infinity)
                            
                            Button(action: {
                                isEditingComment = false
                            }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    } else {
                        HStack {
                            if file.comment.isEmpty {
                                Text("No comment")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .italic()
                            } else {
                                Text(file.comment)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                editedComment = file.comment
                                isEditingComment = true
                            }) {
                                Image(systemName: "pencil")
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Edit comment")
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
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
    
    private func generateOutputFilename(from input: String) -> String {
        let filename = (input as NSString).deletingPathExtension
        let sanitized = FileNameProcessor.processFileName(filename)
        return "\(sanitized)\(preset.fileSuffix).\(preset.fileExtension)"
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
        
        var body: some View {
            VideoFileRowView(
                file: $item,
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
        
        var body: some View {
            VideoFileRowView(
                file: $item,
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
